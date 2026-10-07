begin;
create schema if not exists private;
revoke all on schema private from public,anon;
grant usage on schema private to authenticated,service_role;
create table private.profiles(id uuid primary key references auth.users(id) on delete cascade,name text not null check(length(name) between 1 and 60),email text not null,created_at timestamptz not null default now());
create table private.groups(id uuid primary key default gen_random_uuid(),owner_id uuid not null references private.profiles(id),name text not null check(length(name) between 1 and 40),description text not null default '',cadence integer not null default 14 check(cadence in (7,14,28)),timezone text not null default 'Europe/Brussels',paused boolean not null default false,created_at timestamptz not null default now());
create table private.members(group_id uuid not null references private.groups(id) on delete cascade,user_id uuid not null references private.profiles(id) on delete cascade,role text not null default 'Contributor' check(role in ('Contributor','Reader')),notifications boolean not null default true,joined_at timestamptz not null default now(),primary key(group_id,user_id));
create index members_user on private.members(user_id,group_id);
create table private.issues(id uuid primary key default gen_random_uuid(),group_id uuid not null references private.groups(id) on delete cascade,number integer not null,title text not null check(length(title) between 1 and 80),due_at timestamptz not null,status text not null default 'open' check(status in ('open','compiled')),compiled_at timestamptz,created_at timestamptz not null default now(),unique(group_id,number));
create unique index one_open_issue on private.issues(group_id) where status='open';
create index issues_group on private.issues(group_id,number desc);
create table private.questions(id uuid primary key default gen_random_uuid(),issue_id uuid not null references private.issues(id) on delete cascade,text text not null check(length(text) between 1 and 240),position integer not null,unique(issue_id,position));
create table private.suggestions(id uuid primary key default gen_random_uuid(),group_id uuid not null references private.groups(id) on delete cascade,user_id uuid not null references private.profiles(id),text text not null check(length(text) between 1 and 240),used_at timestamptz,created_at timestamptz not null default now());
create index suggestions_pending on private.suggestions(group_id,created_at) where used_at is null;
create table private.replies(issue_id uuid not null references private.issues(id) on delete cascade,user_id uuid not null references private.profiles(id),answers jsonb not null default '{}',submitted boolean not null default false,revision integer not null default 1,submitted_at timestamptz,updated_at timestamptz not null default now(),primary key(issue_id,user_id));
create table private.reactions(issue_id uuid not null references private.issues(id) on delete cascade,question_id uuid not null references private.questions(id) on delete cascade,author_id uuid not null references private.profiles(id),user_id uuid not null references private.profiles(id) on delete cascade,primary key(question_id,author_id,user_id));
create table private.invites(id uuid primary key default gen_random_uuid(),group_id uuid not null references private.groups(id) on delete cascade,token_hash text not null unique,role text not null default 'Contributor' check(role in ('Contributor','Reader')),expires_at timestamptz not null default now()+interval '7 days',max_uses integer not null default 50,uses integer not null default 0,revoked boolean not null default false,created_at timestamptz not null default now());
create table private.email_jobs(id uuid primary key default gen_random_uuid(),group_id uuid not null references private.groups(id) on delete cascade,issue_id uuid not null references private.issues(id) on delete cascade,user_id uuid not null references private.profiles(id) on delete cascade,kind text not null check(kind in ('open','reminder','ready')),status text not null default 'pending' check(status in ('pending','sending','sent','failed','cancelled')),attempts integer not null default 0,next_attempt_at timestamptz not null default now(),lease_token uuid,lease_until timestamptz,provider_id text,last_error text,created_at timestamptz not null default now(),sent_at timestamptz,unique(issue_id,user_id,kind));
create index email_jobs_due on private.email_jobs(status,next_attempt_at);
create table private.system_status(singleton boolean primary key default true check(singleton),last_tick timestamptz,last_dispatch timestamptz,last_error text);
insert into private.system_status(singleton) values(true);
alter table private.profiles enable row level security;
alter table private.groups enable row level security;
alter table private.members enable row level security;
alter table private.issues enable row level security;
alter table private.questions enable row level security;
alter table private.suggestions enable row level security;
alter table private.replies enable row level security;
alter table private.reactions enable row level security;
alter table private.invites enable row level security;
alter table private.email_jobs enable row level security;
alter table private.system_status enable row level security;
revoke all on all tables in schema private from public,anon,authenticated;
-- No direct table access. All exposed RPCs check identity and group membership.
create function private.ensure_profile() returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid();e text:=auth.jwt()->>'email';n text;
begin
 if u is null or e is null then raise exception 'Please sign in first.' using errcode='42501';end if;
 n:=left(coalesce(nullif(auth.jwt()->'user_metadata'->>'name',''),split_part(e,'@',1)),60);
 insert into private.profiles(id,name,email) values(u,n,e) on conflict(id) do update set email=excluded.email;
 return u;
end $$;
create function private.new_issue(g uuid,num integer,due timestamptz) returns uuid language plpgsql security definer set search_path='' as $$
declare i uuid;q record;pos integer:=0;
begin
 insert into private.issues(group_id,number,title,due_at) values(g,num,'A little catch-up',due) returning id into i;
 for q in select * from private.suggestions where group_id=g and used_at is null order by created_at,id limit 5 for update loop
  insert into private.questions(issue_id,text,position) values(i,q.text,pos);pos:=pos+1;
  update private.suggestions set used_at=now() where id=q.id;
 end loop;
 if pos=0 then
  insert into private.questions(issue_id,text,position) values(i,'What’s one small thing that made your week better?',0),(i,'What have you been reading, watching, or listening to lately?',1),(i,'What’s something you’re looking forward to?',2);
 end if;return i;
end $$;
create function private.queue_email(g uuid,i uuid,k text) returns void language plpgsql security definer set search_path='' as $$
begin
 insert into private.email_jobs(group_id,issue_id,user_id,kind)
 select g,i,m.user_id,k from private.members m
 where m.group_id=g and m.notifications and
 (k='ready' or (m.role='Contributor' and not exists(select 1 from private.replies r where r.issue_id=i and r.user_id=m.user_id and r.submitted)))
 on conflict(issue_id,user_id,kind) do nothing;
end $$;
create function private.close_issue(i uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare iss private.issues;grp private.groups;nextid uuid;local_due timestamp;
begin
 select * into iss from private.issues where id=i;
 select * into grp from private.groups where id=iss.group_id for update;
 select * into iss from private.issues where id=i for update;
 if iss.id is null then raise exception 'Issue not found.';end if;
 if iss.status<>'open' then select id into nextid from private.issues where group_id=iss.group_id and status='open';return nextid;end if;
 update private.issues set status='compiled',compiled_at=now() where id=i;
 update private.email_jobs set status='cancelled' where issue_id=i and kind in ('open','reminder') and status in ('pending','failed');
 if exists(select 1 from private.replies where issue_id=i and submitted) then perform private.queue_email(grp.id,i,'ready');end if;
 local_due:=(iss.due_at at time zone grp.timezone)+make_interval(days=>grp.cadence);
 if local_due at time zone grp.timezone <= now() then local_due:=(now() at time zone grp.timezone)+make_interval(days=>grp.cadence);end if;
 nextid:=private.new_issue(grp.id,iss.number+1,local_due at time zone grp.timezone);
 if not grp.paused then perform private.queue_email(grp.id,nextid,'open');end if;
 return nextid;
end $$;
create function private.issue_json(i uuid,u uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',iss.id,'number',iss.number,'title',iss.title,'date',to_char(iss.due_at at time zone g.timezone,'YYYY-MM-DD'),'due_at',iss.due_at,'status',iss.status,'questionsLocked',exists(select 1 from private.replies where issue_id=i),'questions',coalesce((select jsonb_agg(jsonb_build_object('id',q.id,'text',q.text) order by q.position) from private.questions q where q.issue_id=i),'[]'::jsonb),'responses',coalesce((select jsonb_object_agg(r.user_id::text,jsonb_build_object('answers',r.answers,'submitted',r.submitted,'revision',r.revision,'author',jsonb_build_object('name',p.name,'color',0))) from private.replies r join private.profiles p on p.id=r.user_id where r.issue_id=i and (r.submitted or r.user_id=u)),'{}'::jsonb),'likes',coalesce((select jsonb_object_agg(k,jsonb_build_object('count',ct,'mine',mine)) from (select question_id::text||'-'||author_id::text as k,count(*) ct,bool_or(user_id=u) mine from private.reactions where issue_id=i group by question_id,author_id) a),'{}'::jsonb))
 from private.issues iss join private.groups g on g.id=iss.group_id where iss.id=i;
$$;
create function private.app_state() returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.ensure_profile();result jsonb;
begin
 select jsonb_build_object('user',(select jsonb_build_object('id',p.id,'name',p.name,'email',p.email) from private.profiles p where p.id=u),'groups',coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'name',g.name,'description',g.description,'ownerId',g.owner_id,'cadence',g.cadence,'frequency',case g.cadence when 7 then 'Every week' when 14 then 'Every 2 weeks' else 'Every 4 weeks' end,'timezone',g.timezone,'paused',g.paused,'members',(select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'email',case when m.user_id=u or g.owner_id=u then p.email else null end,'role',m.role,'owner',m.user_id=g.owner_id,'notifications',case when m.user_id=u then m.notifications else null end,'color',0) order by m.joined_at) from private.members m join private.profiles p on p.id=m.user_id where m.group_id=g.id),'issue',(select private.issue_json(i.id,u) from private.issues i where i.group_id=g.id and i.status='open'),'archive',coalesce((select jsonb_agg(private.issue_json(a.id,u) order by a.number desc) from (select id,number from private.issues where group_id=g.id and status='compiled' order by number desc limit 50) a),'[]'::jsonb),'suggestions',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'text',s.text,'userId',s.user_id,'author',p.name) order by s.created_at) from private.suggestions s join private.profiles p on p.id=s.user_id where s.group_id=g.id and s.used_at is null),'[]'::jsonb),'emailStatus',case when g.owner_id=u then (select jsonb_build_object('lastTick',last_tick,'lastDispatch',last_dispatch,'failed',(select count(*) from private.email_jobs j where j.group_id=g.id and j.status='failed'),'pending',(select count(*) from private.email_jobs j where j.group_id=g.id and j.status in ('pending','sending'))) from private.system_status) else null end) order by g.created_at) from private.groups g where exists(select 1 from private.members m where m.group_id=g.id and m.user_id=u)),'[]'::jsonb)) into result;
 return result;
end $$;
create function private.app_mutate(p_action text,p_group uuid,p_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.ensure_profile();g private.groups;m private.members;iss private.issues;r private.replies;inv private.invites;target uuid;q uuid;value text;token text;n integer;revision integer;due timestamptz;
begin
 if octet_length(p_payload::text)>50000 then raise exception 'That update is too large.';end if;
 if p_action='profile' then
  value:=btrim(p_payload->>'name');if value is null or length(value) not between 1 and 60 then raise exception 'Choose a name between 1 and 60 characters.';end if;
  update private.profiles set name=value where id=u;return '{}'::jsonb;
 end if;
 if p_action='create' then
  if (select count(*) from private.groups where owner_id=u)>=10 then raise exception 'You can create up to 10 groups.';end if;
  value:=btrim(p_payload->>'name');if value is null or length(value) not between 1 and 40 then raise exception 'Choose a group name between 1 and 40 characters.';end if;
  if not exists(select 1 from pg_catalog.pg_timezone_names where name=coalesce(p_payload->>'timezone','Europe/Brussels')) then raise exception 'Choose a valid timezone.';end if;
  insert into private.groups(owner_id,name,description,cadence,timezone) values(u,value,left(coalesce(p_payload->>'description',''),300),coalesce((p_payload->>'cadence')::integer,14),coalesce(p_payload->>'timezone','Europe/Brussels')) returning * into g;
  insert into private.members(group_id,user_id,notifications) values(g.id,u,coalesce((p_payload->>'notifications')::boolean,true));
  due:=((now() at time zone g.timezone)::date+7+time '18:00') at time zone g.timezone;
  perform private.new_issue(g.id,1,due);return jsonb_build_object('groupId',g.id);
 end if;
 if p_action='join' then
  select * into inv from private.invites where token_hash=encode(sha256(convert_to(coalesce(p_payload->>'token',''),'UTF8')),'hex') and not revoked and expires_at>now() and uses<max_uses for update;
  if inv.id is null then raise exception 'That invite has expired or was revoked. Ask your friend for a fresh link.';end if;
  if exists(select 1 from private.members where group_id=inv.group_id and user_id=u) then return jsonb_build_object('groupId',inv.group_id);end if;
  if (select count(*) from private.members where group_id=inv.group_id)>=50 then raise exception 'This group has reached its 50-member limit.';end if;
  insert into private.members(group_id,user_id,role,notifications) values(inv.group_id,u,inv.role,coalesce((p_payload->>'notifications')::boolean,true));
  update private.invites set uses=uses+1 where id=inv.id;return jsonb_build_object('groupId',inv.group_id);
 end if;
 select * into g from private.groups where id=p_group for update;
 select * into m from private.members where group_id=p_group and user_id=u;
 if g.id is null or m.user_id is null then raise exception 'You do not have access to this group.' using errcode='42501';end if;
 select * into iss from private.issues where group_id=g.id and status='open' for update;
 if p_action='notifications' then
  update private.members set notifications=coalesce((p_payload->>'enabled')::boolean,false) where group_id=g.id and user_id=u;
  if not coalesce((p_payload->>'enabled')::boolean,false) then update private.email_jobs set status='cancelled' where group_id=g.id and user_id=u and status in ('pending','failed');end if;return '{}'::jsonb;
 elsif p_action='suggest' then
  value:=btrim(p_payload->>'text');if value is null or length(value) not between 1 and 240 then raise exception 'Write a question between 1 and 240 characters.';end if;
  if (select count(*) from private.suggestions where group_id=g.id and used_at is null)>=100 then raise exception 'This group already has 100 upcoming questions.';end if;
  insert into private.suggestions(group_id,user_id,text) values(g.id,u,value);return '{}'::jsonb;
 elsif p_action='remove-suggestion' then
  delete from private.suggestions where id=(p_payload->>'id')::uuid and group_id=g.id and used_at is null and (user_id=u or g.owner_id=u);return '{}'::jsonb;
 elsif p_action='reply' then
  if m.role<>'Contributor' then raise exception 'Readers cannot submit replies.' using errcode='42501';end if;
  if iss.id is null or iss.id<>(p_payload->>'issueId')::uuid or iss.due_at<=now() then raise exception 'This issue has closed. Refresh for the next one.';end if;
  if jsonb_typeof(p_payload->'answers')<>'object' then raise exception 'Please provide your answers.';end if;
  if exists(select 1 from jsonb_each(p_payload->'answers') kv where jsonb_typeof(kv.value)<>'string' or length(kv.value#>>'{}')>5000 or not exists(select 1 from private.questions where issue_id=iss.id and id::text=kv.key)) then raise exception 'Invalid answers. Refresh this issue and try again.';end if;
  if coalesce((p_payload->>'submitted')::boolean,false) and exists(select 1 from private.questions q where q.issue_id=iss.id and length(btrim(coalesce(p_payload->'answers'->>q.id::text,'')))=0) then raise exception 'Answer each question before sharing, or save a draft.';end if;
  select * into r from private.replies where issue_id=iss.id and user_id=u for update;
  revision:=coalesce((p_payload->>'revision')::integer,0);
  if coalesce(r.revision,0)<>revision then raise exception 'Your reply changed in another tab. Refresh before saving again.' using errcode='40001';end if;
  insert into private.replies(issue_id,user_id,answers,submitted,submitted_at) values(iss.id,u,p_payload->'answers',coalesce((p_payload->>'submitted')::boolean,false),case when (p_payload->>'submitted')::boolean then now() else null end)
  on conflict(issue_id,user_id) do update set answers=excluded.answers,submitted=excluded.submitted,submitted_at=excluded.submitted_at,revision=private.replies.revision+1,updated_at=now();return '{}'::jsonb;
 elsif p_action='reaction' then
  q:=(p_payload->>'questionId')::uuid;target:=(p_payload->>'authorId')::uuid;
  if not exists(select 1 from private.questions qu join private.issues i on i.id=qu.issue_id join private.replies rp on rp.issue_id=i.id where qu.id=q and i.group_id=g.id and rp.user_id=target and rp.submitted) then raise exception 'That submitted answer is not available.';end if;
  select issue_id into target from private.questions where id=q;
  if coalesce((p_payload->>'liked')::boolean,false) then insert into private.reactions(issue_id,question_id,author_id,user_id) values(target,q,(p_payload->>'authorId')::uuid,u) on conflict do nothing;
  else delete from private.reactions where question_id=q and author_id=(p_payload->>'authorId')::uuid and user_id=u;end if;return '{}'::jsonb;
 elsif p_action='leave' then
  if g.owner_id=u then raise exception 'The owner must keep access to the group.';end if;
  delete from private.members where group_id=g.id and user_id=u;
  update private.email_jobs set status='cancelled' where group_id=g.id and user_id=u and status in ('pending','failed');return '{}'::jsonb;
 end if;
 if g.owner_id<>u then raise exception 'Only the group owner can do that.' using errcode='42501';end if;
 if p_action='settings' then
  value:=btrim(p_payload->>'name');if value is null or length(value) not between 1 and 40 then raise exception 'Choose a group name between 1 and 40 characters.';end if;
  if not exists(select 1 from pg_catalog.pg_timezone_names where name=p_payload->>'timezone') then raise exception 'Choose a valid timezone.';end if;
  update private.groups set name=value,description=left(coalesce(p_payload->>'description',''),300),cadence=(p_payload->>'cadence')::integer,timezone=p_payload->>'timezone',paused=coalesce((p_payload->>'paused')::boolean,false) where id=g.id;return '{}'::jsonb;
 elsif p_action='issue-details' then
  if iss.id<>(p_payload->>'issueId')::uuid then raise exception 'The issue changed. Refresh first.';end if;
  value:=btrim(p_payload->>'title');if value is null or length(value) not between 1 and 80 then raise exception 'Choose an issue title between 1 and 80 characters.';end if;
  due:=((p_payload->>'date')::date+time '18:00') at time zone g.timezone;
  if due<=now() then raise exception 'Choose a future deadline.';end if;
  update private.issues set title=value,due_at=due where id=iss.id;return '{}'::jsonb;
 elsif p_action in ('questions','include-suggestion') then
  if iss.id<>(p_payload->>'issueId')::uuid then raise exception 'The issue changed. Refresh first.';end if;
  if exists(select 1 from private.replies where issue_id=iss.id) then raise exception 'Questions are locked once someone starts a reply. Suggest a question for the next round instead.';end if;
  if p_action='include-suggestion' then
   select text into value from private.suggestions where id=(p_payload->>'id')::uuid and group_id=g.id and used_at is null for update;
   if value is null then raise exception 'That question is no longer available.';end if;
   select count(*) into n from private.questions where issue_id=iss.id;if n>=10 then raise exception 'Keep an issue to 10 questions or fewer.';end if;
   insert into private.questions(issue_id,text,position) values(iss.id,value,n);update private.suggestions set used_at=now() where id=(p_payload->>'id')::uuid;
  else
   if jsonb_typeof(p_payload->'questions')<>'array' or jsonb_array_length(p_payload->'questions') not between 1 and 10 then raise exception 'Choose 1 to 10 questions.';end if;
   if exists(select 1 from jsonb_array_elements(p_payload->'questions') v where length(btrim(v->>'text')) not between 1 and 240 or v->>'text' is null) then raise exception 'Write a valid question for every prompt.';end if;
   delete from private.questions where issue_id=iss.id;
   insert into private.questions(issue_id,text,position) select iss.id,btrim(v->>'text'),ord::integer-1 from jsonb_array_elements(p_payload->'questions') with ordinality a(v,ord);
  end if;return '{}'::jsonb;
 elsif p_action='compile' then
  if iss.id<>(p_payload->>'issueId')::uuid then raise exception 'The issue has already changed. Refresh first.';end if;
  if not exists(select 1 from private.replies where issue_id=iss.id and submitted) then raise exception 'At least one person needs to share a reply first.';end if;
  perform private.close_issue(iss.id);return jsonb_build_object('issueId',iss.id);
 elsif p_action='invite' then
  token:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  insert into private.invites(group_id,token_hash,role) values(g.id,encode(sha256(convert_to(token,'UTF8')),'hex'),coalesce(p_payload->>'role','Contributor'));
  return jsonb_build_object('token',token,'expiresAt',now()+interval '7 days');
 elsif p_action='revoke-invites' then
  update private.invites set revoked=true where group_id=g.id;return '{}'::jsonb;
 elsif p_action='member-role' then
  target:=(p_payload->>'id')::uuid;if target=g.owner_id then raise exception 'The owner remains a contributor.';end if;
  update private.members set role=p_payload->>'role' where group_id=g.id and user_id=target;return '{}'::jsonb;
 elsif p_action='remove-member' then
  target:=(p_payload->>'id')::uuid;if target=g.owner_id then raise exception 'The owner cannot be removed.';end if;
  delete from private.members where group_id=g.id and user_id=target;
  update private.email_jobs set status='cancelled' where group_id=g.id and user_id=target and status in ('pending','failed');return '{}'::jsonb;
 else raise exception 'Unknown action.';end if;
end $$;
create function public.ll_state() returns jsonb language sql security invoker set search_path='' as $$select private.app_state()$$;
create function public.ll_mutate(p_action text,p_group uuid default null,p_payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select private.app_mutate(p_action,p_group,p_payload)$$;
revoke all on all functions in schema private from public,anon,authenticated;
grant execute on function private.app_state(),private.app_mutate(text,uuid,jsonb) to authenticated;
revoke all on function public.ll_state(),public.ll_mutate(text,uuid,jsonb) from public,anon;
grant execute on function public.ll_state(),public.ll_mutate(text,uuid,jsonb) to authenticated;
commit;
