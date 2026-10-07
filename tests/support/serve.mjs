// Local UI acceptance harness. Synthetic auth only; never deployed to Pages.
import http from 'node:http';
import {readFile} from 'node:fs/promises';
import {resolve,extname} from 'node:path';
import {PGlite} from '@electric-sql/pglite';
const db=new PGlite();
await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key);create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;create function auth.uid() returns uuid language sql stable as $$select (auth.jwt()->>'sub')::uuid$$;grant usage on schema auth to authenticated,service_role;grant execute on all functions in schema auth to authenticated,service_role;`);
for(const f of ['202610070001_core.sql','202610070002_jobs.sql'])await db.exec(await readFile('supabase/migrations/'+f,'utf8'));
const users=new Map(),sessions=new Map();let queue=Promise.resolve();
function json(r,data,status=200){r.writeHead(status,{'Content-Type':'application/json'});r.end(JSON.stringify(data))}
const server=http.createServer(async(req,res)=>{try{
 const path=new URL(req.url,'http://127.0.0.1:4173').pathname;
 if(req.method==='POST'){
  let raw='';for await(const c of req)raw+=c;if(raw.length>60000)return json(res,{message:'Too large'},413);const body=JSON.parse(raw);
  const task=async()=>{
   if(path==='/auth/v1/otp'){if(!body.email.endsWith('@example.invalid'))return json(res,{message:'UI test harness: use an @example.invalid email'},400);return json(res,{})}
   if(path==='/auth/v1/verify'){
    if(body.token!=='123456')return json(res,{message:'Invalid test code'},400);
    let id=users.get(body.email);if(!id){id=crypto.randomUUID();users.set(body.email,id);await db.exec('reset role');await db.query('insert into auth.users values($1)',[id]);}
    const token=crypto.randomUUID();sessions.set(token,{sub:id,email:body.email,role:'authenticated'});return json(res,{access_token:token,refresh_token:token,expires_in:3600,user:{id,email:body.email}});
   }
   if(path==='/auth/v1/logout'){sessions.delete(req.headers.authorization?.slice(7));return json(res,{})}
   const claims=sessions.get(req.headers.authorization?.slice(7));if(!claims)return json(res,{message:'Sign in'},401);
   await db.exec('reset role');await db.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify(claims)]);await db.exec('set role authenticated');
   if(path==='/rest/v1/rpc/ll_state')return json(res,(await db.query('select public.ll_state() data')).rows[0].data);
   if(path==='/rest/v1/rpc/ll_mutate')return json(res,(await db.query('select public.ll_mutate($1,$2,$3::jsonb) data',[body.p_action,body.p_group,JSON.stringify(body.p_payload)])).rows[0].data);
   return json(res,{message:'Unknown endpoint'},404);
  };
  queue=queue.then(task).catch(e=>json(res,{message:e.message},400));return;
 }
 if(path==='/config.js'){res.writeHead(200,{'Content-Type':'application/javascript'});return res.end('window.LETTERLOOP_CONFIG={supabaseUrl:"http://127.0.0.1:4173",supabaseAnonKey:"local-ui-test"};')}
 const file=resolve('web','.'+(path==='/'?'/index.html':path));if(!file.startsWith(resolve('web')+'/'))return json(res,{},403);
 const types={'.html':'text/html','.css':'text/css','.js':'application/javascript','.png':'image/png'};res.writeHead(200,{'Content-Type':types[extname(file)]||'application/octet-stream'});res.end(await readFile(file));
}catch(e){json(res,{message:e.message},404)}});
server.listen(4173,'127.0.0.1',()=>console.log('Local UI test harness: 4173, @example.invalid emails, code 123456. No outgoing email.'));
