'use strict';
const Backend = (()=>{
 const config=window.LETTERLOOP_CONFIG||{}; const configured=!!config.supabaseUrl&&!!config.supabaseAnonKey;
 const storageKey='letterloop-session-'+(config.supabaseUrl||'unconfigured');let session=null,refreshing=null;
 try{session=JSON.parse(localStorage.getItem(storageKey))}catch{}
 function keep(s){session=s?{access_token:s.access_token,refresh_token:s.refresh_token,expires_at:s.expires_at||Math.floor(Date.now()/1000)+s.expires_in,user:s.user}:null;try{session?localStorage.setItem(storageKey,JSON.stringify(session)):localStorage.removeItem(storageKey)}catch{}return session}
 async function request(path,body,auth=true){if(!configured)throw Error('The shared database is not connected yet.');if(auth)await ready();const r=await fetch(config.supabaseUrl+path,{method:'POST',headers:{apikey:config.supabaseAnonKey,'Content-Type':'application/json',...(auth&&session?{Authorization:'Bearer '+session.access_token}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(20000)});const data=await r.json().catch(()=>null);if(!r.ok){if(r.status===401&&auth)keep(null);throw Error(data?.msg||data?.message||data?.error_description||'Could not save that change. Please try again.')}return data}
 async function ready(){if(!session)throw Error('Please sign in to continue.');if(session.expires_at>Date.now()/1000+60)return;if(!refreshing)refreshing=request('/auth/v1/token?grant_type=refresh_token',{refresh_token:session.refresh_token},false).then(keep).catch(e=>{keep(null);throw e}).finally(()=>refreshing=null);await refreshing}
 async function sendCode(email){await request('/auth/v1/otp',{email,create_user:true},false)}
 async function verifyCode(email,token){keep(await request('/auth/v1/verify',{email,token,type:'email'},false))}
 async function signout(){try{if(session)await request('/auth/v1/logout',{},true)}finally{keep(null)}}
 return {configured,hasSession:()=>!!session,sendCode,verifyCode,signout,ready,rpc:(name,p={})=>request('/rest/v1/rpc/'+name,p),state:()=>request('/rest/v1/rpc/ll_state',{}),mutate:(action,group,payload={})=>request('/rest/v1/rpc/ll_mutate',{p_action:action,p_group:group,p_payload:payload})};
})();
