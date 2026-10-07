begin;
create function private.tick() returns jsonb language plpgsql security definer set search_path='' as $$
declare i record;closed integer:=0;
begin
 if not pg_try_advisory_xact_lock(7193512026) then return jsonb_build_object('busy',true);end if;
 for i in select iss.id,iss.group_id,iss.due_at from private.issues iss join private.groups g on g.id=iss.group_id where iss.status='open' and not g.paused order by iss.due_at limit 100 loop
  if i.due_at<=now() then perform private.close_issue(i.id);closed:=closed+1;
  elsif i.due_at<=now()+interval '48 hours' then perform private.queue_email(i.group_id,i.id,'reminder');end if;
 end loop;
 update private.system_status set last_tick=now(),last_error=null where singleton;
 return jsonb_build_object('closed',closed);
end $$;
create function private.claim_email(p_limit integer default 20) returns jsonb language plpgsql security definer set search_path='' as $$
declare capacity integer;result jsonb;
begin
 perform 1 from private.system_status where singleton for update;
 update private.email_jobs j set status='cancelled',lease_token=null where status in ('pending','failed','sending') and
 (not exists(select 1 from private.members m where m.group_id=j.group_id and m.user_id=j.user_id and m.notifications)
 or (kind in ('open','reminder') and (exists(select 1 from private.replies r where r.issue_id=j.issue_id and r.user_id=j.user_id and r.submitted) or exists(select 1 from private.issues i where i.id=j.issue_id and i.status<>'open') or exists(select 1 from private.members m where m.group_id=j.group_id and m.user_id=j.user_id and m.role='Reader'))));
 select greatest(0,260-count(*)::integer) into capacity from private.email_jobs where (status='sent' and sent_at>=(now() at time zone 'UTC')::date at time zone 'UTC') or (status='sending' and lease_until>now());
 with candidates as (
  select id from private.email_jobs where ((status in ('pending','failed') and next_attempt_at<=now()) or (status='sending' and lease_until<now())) and attempts<5 and not exists(select 1 from private.groups g where g.id=email_jobs.group_id and g.paused) order by created_at limit least(greatest(p_limit,0),20,capacity) for update skip locked
 ),claimed as (
  update private.email_jobs j set status='sending',attempts=attempts+1,lease_token=gen_random_uuid(),lease_until=now()+interval '10 minutes'
  from candidates c where j.id=c.id returning j.*
 ) select coalesce(jsonb_agg(jsonb_build_object('id',j.id,'leaseToken',j.lease_token,'kind',j.kind,'email',p.email,'name',p.name,'groupId',g.id,'groupName',g.name,'issueId',i.id,'issueTitle',i.title,'deadline',to_char(i.due_at at time zone g.timezone,'DD Mon YYYY, HH24:MI')||' ('||g.timezone||')')),'[]'::jsonb)
 into result from claimed j join private.profiles p on p.id=j.user_id join private.groups g on g.id=j.group_id join private.issues i on i.id=j.issue_id;
 return result;
end $$;
create function private.finish_email(p_id uuid,p_lease uuid,p_provider_id text default null,p_error text default null) returns boolean language plpgsql security definer set search_path='' as $$
begin
 update private.email_jobs set status=case when p_error is null then 'sent' else 'failed' end,provider_id=left(p_provider_id,200),last_error=left(p_error,200),sent_at=case when p_error is null then now() else null end,next_attempt_at=now()+make_interval(mins=>least(120,power(2,attempts)::integer*5)),lease_until=null,lease_token=null
 where id=p_id and status='sending' and lease_token=p_lease;
 if not found then return false;end if;
 update private.system_status set last_dispatch=now(),last_error=case when p_error is null then null else 'Email delivery failed; inspect provider and job status.' end where singleton;
 return true;
end $$;
create function public.ll_tick() returns jsonb language sql security invoker set search_path='' as $$select private.tick()$$;
create function public.ll_claim_email(p_limit integer default 20) returns jsonb language sql security invoker set search_path='' as $$select private.claim_email(p_limit)$$;
create function public.ll_finish_email(p_id uuid,p_lease uuid,p_provider_id text default null,p_error text default null) returns boolean language sql security invoker set search_path='' as $$select private.finish_email(p_id,p_lease,p_provider_id,p_error)$$;
revoke all on function private.tick(),private.claim_email(integer),private.finish_email(uuid,uuid,text,text),public.ll_tick(),public.ll_claim_email(integer),public.ll_finish_email(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function private.tick(),private.claim_email(integer),private.finish_email(uuid,uuid,text,text),public.ll_tick(),public.ll_claim_email(integer),public.ll_finish_email(uuid,uuid,text,text) to service_role;
commit;
