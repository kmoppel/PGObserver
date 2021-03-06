-- the most important sproc - compares function performance to historical values


CREATE OR REPLACE FUNCTION sprocs_evaluate_performance_last_hour(
  IN  p_date			timestamp without time zone default NULL,
  IN  p_hour			integer default NULL,
  IN  p_is_eval_averages	boolean default 'false',
  IN  p_is_combine_hosts   	boolean default 'true',
  OUT host_name			text array,
  OUT sproc_name		text, 
  OUT calls			bigint,
  OUT total_time		bigint,
  OUT avg_time			bigint,
  OUT time_percent_increase	integer
)
  RETURNS setof record AS
$$
DECLARE
  l_number_of_weeks	integer;
  l_alert_percent	integer;
  l_time_threshod	integer;
  i			integer;
  l_date		timestamp without time zone;
  l_hour		integer;
  l_is_calc_for_last_hour boolean;
  l_dates_array		timestamp without time zone array;

BEGIN

  l_is_calc_for_last_hour := p_date IS NULL AND p_hour IS NULL;
  -- fix hour & date
  if (p_date IS NULL) then
     p_hour := extract (hour from current_time);
     if (p_hour = 0) then
        p_hour := 23;
        p_date := current_date - interval '1 day';
     else
        p_hour := p_hour -1;   
        p_date := current_date;
     end if;
  end if;

  if (p_hour IS NULL) then
     p_hour := extract (hour from current_time);
     if (p_hour = 0) then
        p_hour := 23;
        p_date := p_date - interval '1 day';
     else
        p_hour := p_hour -1;   
     end if;
  end if;
   
  -- make sure data for all needed periods is there
  select mc_config_value::integer
    from monitoring_configuration
   where mc_config_name = 'total_time_same_days_hourly_past_samples'
    into l_number_of_weeks;

  select mc_config_value::integer
    from monitoring_configuration
   where mc_config_name = 'total_time_same_days_hourly_percent'
    into l_alert_percent;


  select mc_config_value::integer
    from monitoring_configuration
   where mc_config_name = 'total_time_same_days_threshold'
    into l_time_threshod;


  i := 0;
  l_date := p_date;
  l_hour := p_hour;
  while i <= l_number_of_weeks loop
    perform calc_sprocs_summary (l_date, l_hour);

--raise notice '%',l_date;

    if (i > 0) then 
      l_dates_array := l_dates_array || l_date;
    end if;

    l_date := l_date - interval '7 day';
    i := i+1;
  end loop;

  drop table if exists tmp_prev_sums;
  create temporary table tmp_prev_sums (
    ss_host_id		integer array,
    ss_sproc_name	text,
    weeks_cnt		integer,	-- number of weeks for which we have data from the sproc !
    sum_calls		bigint,
    sum_total_time	bigint
  );

  if (p_is_combine_hosts) then
	  insert into tmp_prev_sums
	  select array_agg(distinct ss_host_id), ss_sproc_name, count(distinct ss_date) as weeks_cnt, sum(ss_calls) as sum_calls, sum(ss_total_time) as sum_total_time
	    from sprocs_summary
	   where ss_hour = p_hour
	     and ss_date = ANY (l_dates_array) and
		 not ss_is_suspect and
		 not exists (select 1 
			       from performance_ignore_list 
			      where (pil_host_id IS NULL or pil_host_id = ss_host_id) AND 
			            (pil_object_name IS NULL or pil_object_name = ss_sproc_name)
			     )
	     
	  group by ss_sproc_name;
  else
	  insert into tmp_prev_sums
	  select array_agg(distinct ss_host_id), ss_sproc_name, count(distinct ss_date) as weeks_cnt, sum(ss_calls) as sum_calls, sum(ss_total_time) as sum_total_time
	    from sprocs_summary
	   where ss_hour = p_hour and
	         ss_date = ANY (l_dates_array) and
		 not ss_is_suspect
	  group by ss_host_id, ss_sproc_name;
  end if;

  update tmp_prev_sums 
     set sum_calls = 1
   where sum_calls = 0;	----- fix Apr14 to prevent divide by zero
  update tmp_prev_sums 
     set sum_total_time = 1
   where sum_total_time = 0;	----- fix Apr14 to prevent divide by zero


  -- insert rows for 'new functions' so they won't be ignored if heavy and don't have hisotry 
  insert into tmp_prev_sums (ss_host_id, ss_sproc_name, weeks_cnt, sum_calls, sum_total_time )
  select array[ss.ss_host_id], ss.ss_sproc_name, 1, 1, 1
    from sprocs_summary ss
   where ss.ss_date = p_date and
	 ss.ss_hour = p_hour and
	 not ss.ss_is_suspect and
	 ss.ss_total_time > l_time_threshod and
	 ss.ss_calls > 0 and
	 not exists ( select 1 
		      from tmp_prev_sums tmp
		       where ss.ss_host_id = ANY(tmp.ss_host_id) and
			     ss.ss_sproc_name = tmp.ss_sproc_name );


  -- average results over non-zero values
  if (p_is_combine_hosts) then

	  RETURN QUERY
	  select array_agg(hosts.host_name), ss.ss_sproc_name, sum(ss.ss_calls)::bigint, sum(ss.ss_total_time)::bigint,  
		 (sum(ss.ss_total_time) / sum (ss.ss_calls))::bigint,
		 case when p_is_eval_averages then
			((((avg(1.0*ss.ss_total_time/ss.ss_calls)) /  (avg(1.0*tmp.sum_total_time/tmp.sum_calls))) - 1.0) * 100.0)::integer
		 else	
			(((sum(1.0*ss.ss_total_time) /  (sum(1.0*tmp.sum_total_time/tmp.weeks_cnt))) - 1.0) * 100.0)::integer
		 end
	    from sprocs_summary ss
	   inner join tmp_prev_sums tmp
	      on tmp.ss_sproc_name = ss.ss_sproc_name
	   inner join hosts
	      on hosts.host_id = ss.ss_host_id
	   where ss.ss_date = p_date and
		 ss.ss_hour = p_hour and
	 	 ss.ss_sproc_name != ' ' and -- ignore the host totals
		 not ss.ss_is_suspect and
		 tmp.sum_total_time > 0 and
		 tmp.sum_calls > 0 and
		 ss.ss_calls > 0 and
		 tmp.weeks_cnt > 0 and
 		 case when p_is_eval_averages then
			'true'
 		 else
 		        1.0*tmp.sum_total_time/tmp.weeks_cnt * (1.0+1.0*l_alert_percent/100.0) < ss.ss_total_time
 		 end and
		 not exists (select 1 
			       from performance_ignore_list 
			      where (pil_host_id IS NULL or pil_host_id = hosts.host_id) AND 
				     (pil_object_name IS NULL or pil_object_name = ss.ss_sproc_name)
			    ) 
-- filtering only without combined hosts !!!!   	and         ( not l_is_calc_for_last_hour OR is_to_be_reported (NULL,'sproc',ss.ss_sproc_name,ss.ss_total_time) ) -- check reporting threshold only on current day report
 		 
	   group by ss.ss_sproc_name
	   having 
 		 avg(1.0*tmp.sum_total_time/tmp.sum_calls) > 0 and
 		 sum(1.0*tmp.sum_total_time/tmp.weeks_cnt) > 0 and
		 avg(tmp.sum_calls) > 0 and
		 avg(tmp.weeks_cnt) > 0 and
		 sum(ss.ss_total_time) > l_time_threshod and
		 case when p_is_eval_averages then
			avg(1.0*tmp.sum_total_time/tmp.sum_calls) * (1.0+1.0*l_alert_percent/100.0) < avg(1.0*ss.ss_total_time/ss.ss_calls)
		 else	
			'true'
		 end
	   order by 6 desc;

  else  -- do not combine hosts
	  RETURN QUERY
          select t.host_name,t.sproc_name,t.calls,t.total_time,t.avg_time,t.time_percent_increase	
	  from (

	  select ss.ss_host_id host_id,array[hosts.host_name] host_name, ss.ss_sproc_name sproc_name, ss.ss_calls calls, ss.ss_total_time total_time,  
		 (ss.ss_total_time / ss.ss_calls)::bigint avg_time,
		 case when p_is_eval_averages then
			((((1.0*ss.ss_total_time/ss.ss_calls) /  (1.0*tmp.sum_total_time/tmp.sum_calls)) - 1.0) * 100.0)::integer
		 else	
			(((1.0*ss.ss_total_time /  (1.0*tmp.sum_total_time/tmp.weeks_cnt)) - 1.0) * 100.0)::integer
		 end time_percent_increase
	    from sprocs_summary ss
	   inner join tmp_prev_sums tmp
	      on ss.ss_host_id = ANY(tmp.ss_host_id) and
		 tmp.ss_sproc_name = ss.ss_sproc_name
	   inner join hosts
	      on hosts.host_id = ss.ss_host_id
	   where ss.ss_date = p_date and
		 ss.ss_hour = p_hour and
		 ss.ss_sproc_name != ' ' and -- ignore the host totals
		 not ss.ss_is_suspect and
		 ss.ss_total_time > l_time_threshod and
		 tmp.sum_total_time > 0 and
		 ss.ss_calls > 0 and
		 1.0*tmp.sum_total_time/tmp.weeks_cnt > 0 and
		 1.0*tmp.sum_total_time/tmp.sum_calls > 0 and
		 tmp.sum_calls > 0 and
		 tmp.weeks_cnt > 0 and		 
		 case when p_is_eval_averages then
			1.0*tmp.sum_total_time/tmp.sum_calls * (1.0+1.0*l_alert_percent/100.0) < (1.0*ss.ss_total_time/ss.ss_calls)
		 else	
		        1.0*tmp.sum_total_time/tmp.weeks_cnt * (1.0+1.0*l_alert_percent/100.0) < ss.ss_total_time
		 end and
		 not exists (select 1 
			       from performance_ignore_list 
			      where (pil_host_id IS NULL or pil_host_id = hosts.host_id) AND 
				     (pil_object_name IS NULL or pil_object_name = ss.ss_sproc_name)
			    ) and
   	         ( not l_is_calc_for_last_hour OR is_to_be_reported (ss.ss_host_id,'sproc',ss.ss_sproc_name,ss.ss_total_time) ) -- check reporting threshold only on current day report
	   ) t
	   where 
   	         ( not l_is_calc_for_last_hour OR is_to_be_reported (t.host_id,'sproc',t.sproc_name,t.total_time) ) -- check reporting threshold only on current day report
	   order by 6 desc; 
  end if;	   
	   
           
END;
$$
  LANGUAGE 'plpgsql';
