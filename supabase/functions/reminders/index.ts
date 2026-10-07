// No SDK dependency. Secrets are configured in Supabase, never in GitHub Pages.
const required=(name:string)=>{const v=Deno.env.get(name);if(!v)throw Error('Missing '+name);return v};
const escape=(s:string)=>s.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
async function rpc(name:string,body:Record<string,unknown>={}){const r=await fetch(required('SUPABASE_URL')+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:required('SUPABASE_SERVICE_ROLE_KEY'),Authorization:'Bearer '+required('SUPABASE_SERVICE_ROLE_KEY'),'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(15000)});if(!r.ok)throw Error('Database operation failed: '+name);return await r.json()}
Deno.serve(async(req:Request)=>{
 if(req.method!=='POST')return new Response('Method not allowed',{status:405});
 const secret=Deno.env.get('JOB_SECRET');if(!secret||req.headers.get('x-job-secret')!==secret)return new Response('Unauthorized',{status:401});
 try{
  required('BREVO_API_KEY');required('BREVO_SENDER_EMAIL');const app=new URL(required('APP_URL'));if(app.protocol!=='https:')throw Error('APP_URL must use HTTPS');
  const tick=await rpc('ll_tick');const jobs=await rpc('ll_claim_email',{p_limit:10});let sent=0,failed=0;
  const deliver=async(j:any)=>{
   const link=new URL(app.href);link.hash='group='+encodeURIComponent(j.groupId)+'&issue='+encodeURIComponent(j.issueId);
   const subject=j.kind==='ready'?j.groupName+': your stories are together':j.groupName+': '+(j.kind==='reminder'?'a little reminder to reply':'a new round of questions');
   const intro=j.kind==='ready'?'Your group’s submitted answers are ready to read.':j.kind==='reminder'?'There’s still time to share your story before '+j.deadline+'.':'There are new questions waiting for your group. Reply by '+j.deadline+'.';
   const settings=new URL(app.href);settings.hash='group='+encodeURIComponent(j.groupId)+'&page=settings';
   try{
    const r=await fetch('https://api.brevo.com/v3/smtp/email',{method:'POST',headers:{'api-key':required('BREVO_API_KEY'),'Content-Type':'application/json',accept:'application/json'},body:JSON.stringify({sender:{name:Deno.env.get('BREVO_SENDER_NAME')||'Your people',email:required('BREVO_SENDER_EMAIL')},to:[{name:j.name,email:j.email}],subject,htmlContent:`<div style="font-family:Arial,sans-serif;max-width:560px;margin:auto;padding:30px;color:#302e29"><h2>${escape(j.groupName)}</h2><p>${escape(intro)}</p><p><a href="${escape(link.href)}">${j.kind==='ready'?'Read everyone’s stories':'Open your Letterloop'}</a></p><p style="font-size:12px;color:#777">You receive these updates because you joined this group and enabled email updates. <a href="${escape(settings.href)}">Turn off email updates</a></p></div>`,textContent:intro+'\n\n'+link.href+'\n\nManage email updates: '+settings.href,headers:{idempotencyKey:j.id},tags:['letterloop-'+j.kind]}),signal:AbortSignal.timeout(12000)});
    if(!r.ok){await rpc('ll_finish_email',{p_id:j.id,p_lease:j.leaseToken,p_error:'Email provider returned HTTP '+r.status});failed++;return}
    const result=await r.json();await rpc('ll_finish_email',{p_id:j.id,p_lease:j.leaseToken,p_provider_id:result.messageId||null});sent++;
   }catch{await rpc('ll_finish_email',{p_id:j.id,p_lease:j.leaseToken,p_error:'Delivery could not be confirmed; queued for retry.'});failed++}
  };
  for(let offset=0;offset<jobs.length;offset+=5)await Promise.all(jobs.slice(offset,offset+5).map(deliver));
  return Response.json({tick,claimed:jobs.length,sent,failed},{status:failed?503:200});
 }catch{return Response.json({error:'Reminder job failed. Check server secrets and database migrations.'},{status:503})}
});
