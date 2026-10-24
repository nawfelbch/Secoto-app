'use strict';
const http=require('http'),fs=require('fs'),path=require('path');
const root=path.resolve(__dirname,'dist'),port=4173;
const frames=new Set(['1M','1w','1d','4h','1h','15m','5m','1m','1month','1week','1day','15min','5min','1min']);
const series=new Set(['VIXCLS','BAMLH0A0HYM2','T10Y2Y']);
const types={'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8'};
const send=(res,status,data,type='application/json; charset=utf-8')=>{res.writeHead(status,{'Content-Type':type,'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'});res.end(typeof data==='string'?data:JSON.stringify(data))};
const server=http.createServer(async(req,res)=>{
try{
if(!['127.0.0.1:'+port,'localhost:'+port].includes(req.headers.host))return send(res,403,{error:'Hôte interdit'});
if(req.headers.origin&&!['http://127.0.0.1:'+port,'http://localhost:'+port].includes(req.headers.origin))return send(res,403,{error:'Origine interdite'});
if(req.method!=='GET')return send(res,405,{error:'Lecture uniquement'});
let local=new URL(req.url,'http://127.0.0.1:'+port);
if(local.pathname==='/api/health')return send(res,200,{service:'edge-atlas-personal',readOnly:true});
if(local.pathname.startsWith('/api/')){
let target,type='application/json; charset=utf-8';
if(local.pathname==='/api/fred'){let id=local.searchParams.get('id');if(!series.has(id))return send(res,400,{error:'Série non autorisée'});target=new URL('https://fred.stlouisfed.org/graph/fredgraph.csv');target.searchParams.set('id',id);type='text/csv; charset=utf-8'}
else if(['/api/binance','/api/twelve'].includes(local.pathname)){let symbol=local.searchParams.get('symbol'),interval=local.searchParams.get('interval');if(!symbol||!/^[-A-Za-z0-9_./:^ ]{1,40}$/.test(symbol)||!frames.has(interval))return send(res,400,{error:'Symbole ou unité invalide'});let twelve=local.pathname==='/api/twelve';target=new URL(twelve?'https://api.twelvedata.com/time_series':'https://api.binance.com/api/v3/klines');target.searchParams.set('symbol',symbol);target.searchParams.set('interval',interval);if(twelve){let dataKey=req.headers['x-data-key'];if(typeof dataKey!=='string'||!/^[A-Za-z0-9_-]{5,256}$/.test(dataKey))return send(res,400,{error:'Clé de données manquante ou invalide'});target.searchParams.set('apikey',dataKey);target.searchParams.set('outputsize','500');target.searchParams.set('timezone','UTC');target.searchParams.set('order','desc')}else target.searchParams.set('limit','500')}
else return send(res,404,{error:'Endpoint non autorisé'});
let upstream=await fetch(target,{signal:AbortSignal.timeout(25000),redirect:'error',headers:{Accept:type}});
if(!upstream.ok)return send(res,upstream.status,{error:'Source indisponible : HTTP '+upstream.status});
let text=await upstream.text();if(Buffer.byteLength(text)>8*1024*1024)return send(res,502,{error:'Réponse trop volumineuse'});return send(res,200,text,type)
}
let decoded=decodeURIComponent(local.pathname),file=path.resolve(root,'.'+(decoded==='/'?'/index.html':decoded));if(!file.startsWith(root+path.sep))return send(res,403,{error:'Chemin interdit'});
if(!['.html','.js','.css'].includes(path.extname(file)))return send(res,404,{error:'Fichier non distribué'});
fs.readFile(file,(err,data)=>{if(err)return send(res,404,{error:'Fichier absent'});res.writeHead(200,{'Content-Type':types[path.extname(file)],'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'});res.end(data)})
}catch(err){send(res,502,{error:err.name==='TimeoutError'?'Délai source dépassé':'Connexion à la source impossible'})}
});
server.listen(port,'127.0.0.1',()=>console.log('EDGE ATLAS personnel — http://127.0.0.1:4173/#radar\nLecture de données uniquement. Clés non enregistrées. Garder cette fenêtre ouverte ; Ctrl+C pour arrêter.'));
server.on('error',err=>{console.error(err.code==='EADDRINUSE'?'Le port 4173 est déjà utilisé. Arrêtez l’ancien serveur avant de relancer.':'Impossible de démarrer le serveur local.');process.exitCode=1});

