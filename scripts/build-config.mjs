import {writeFile} from 'node:fs/promises';
const url=process.env.SUPABASE_URL || '';const key=process.env.SUPABASE_ANON_KEY || '';
if(url && !/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url)) throw Error('Expected a Supabase HTTPS project URL.');
if(key && !key.startsWith('sb_publishable_')){try{const claims=JSON.parse(Buffer.from(key.split('.')[1],'base64url'));if(claims.role!=='anon')throw Error()}catch{throw Error('Only a publishable/anon key may be included in the browser build.')}}
await writeFile('web/config.js','window.LETTERLOOP_CONFIG = '+JSON.stringify({supabaseUrl:url,supabaseAnonKey:key})+';\n');
console.log(url&&key?'Public Supabase configuration written.':'No project connected yet; the site will display setup status.');
