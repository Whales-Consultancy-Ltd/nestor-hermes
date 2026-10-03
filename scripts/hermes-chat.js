#!/usr/bin/env node
// Terminal interactif Hermes — REPL local vers le conteneur `nestor-hermes`
// (Ollama, https://nestor-ai.biz-4-africa.com/hermes). Aucun secret : lecture seule
// sur une API publique. Voir WORKPLAN.md §4 pour l'infra et §6 bis pour les scripts.
//
//   node scripts/hermes-chat.js              # llama3.2:3b, conversation
//   node scripts/hermes-chat.js -m nous-hermes2
//   node scripts/hermes-chat.js -s "tu es BIZ4A" -p "bonjour"   # one-shot, sans REPL
const readline = require('readline');
const fs = require('fs');
const path = require('path');

const BASE = process.env.HERMES_URL || 'https://nestor-ai.biz-4-africa.com/hermes';
const HISTORY = path.join(process.env.HOME || '/tmp', '.config/nestor/hermes-chat.history');

function arg(flag, dflt) {
  const i = process.argv.indexOf(flag);
  return i > -1 && process.argv[i + 1] ? process.argv[i + 1] : dflt;
}

const state = {
  model: arg('-m', 'llama3.2:3b'),
  system: arg('-s', null),
  messages: [],
  temperature: 0.7,
  numPredict: 900,
  quiet: false,
};

async function api(pathname, opts) {
  const r = await fetch(BASE + pathname, opts);
  if (!r.ok) throw new Error(`HTTP ${r.status} ${r.statusText}`);
  return r;
}

// Liste les modeles vraiment presents sur l'instance (et pas ceux du README).
async function listModels() {
  const r = await api('/api/tags');
  const { models = [] } = await r.json();
  return models.map((m) => ({
    name: m.name,
    size: (m.size / 1e9).toFixed(1) + ' Go',
    params: m.details?.parameter_size || '?',
  }));
}

// Charge le modele et affiche le contexte reel de l'instance.
async function status() {
  const models = await listModels();
  const ps = await (await api('/api/ps')).json().catch(() => ({ models: [] }));
  const loaded = ps.models.map((m) => m.name).join(', ') || 'aucun (chargement a la demande)';
  console.log(`endpoint  ${BASE}`);
  console.log(`modele    ${state.model}`);
  console.log(`sur place ${models.map((m) => `${m.name} (${m.size}, ${m.params})`).join('\n          ')}`);
  console.log(`charge    ${loaded}`);
  console.log(`contexte  ${state.messages.length} message(s)`);
}

// Une generation, en flux. Renvoie le texte assemble et les metriques.
async function generate(userText) {
  state.messages.push({ role: 'user', content: userText });
  const t0 = Date.now();
  const body = {
    model: state.model,
    messages: state.system ? [{ role: 'system', content: state.system }, ...state.messages] : state.messages,
    stream: true,
    keep_alive: '30m',
    options: { temperature: state.temperature, num_predict: state.numPredict },
  };
  const res = await api('/api/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });

  const dec = new TextDecoder();
  let buf = '';
  let text = '';
  let done = null;
  for await (const chunk of res.body) {
    buf += dec.decode(chunk, { stream: true });
    const lines = buf.split('\n');
    buf = lines.pop();
    for (const line of lines) {
      if (!line.trim()) continue;
      let j;
      try { j = JSON.parse(line); } catch { continue; }
      if (j.message?.content) { text += j.message.content; if (!state.quiet) process.stdout.write(j.message.content); }
      if (j.done) done = j;
    }
  }
  state.messages.push({ role: 'assistant', content: text });

  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  const evalCount = done?.eval_count ?? 0;
  const promptCount = done?.prompt_eval_count ?? 0;
  const tps = evalCount ? (evalCount / (done.total_duration / 1e9)).toFixed(1) : '?';
  const metrics = `[${state.model} | ${secs}s | ${promptCount}→${evalCount} tok | ${tps} tok/s`
    + (done?.done_reason && done.done_reason !== 'stop' ? ` | done_reason=${done.done_reason}` : '')
    + (evalCount >= state.numPredict ? ' | ⚠ tronque (num_predict atteint)' : '') + ']';
  if (state.quiet) console.error(metrics);
  else console.log(`\n\n${metrics}`);
  return text;
}

const HELP = `commandes :
  /aide              cette liste
  /stat              endpoint, modeles presents, modele charge, taille du contexte
  /modele [nom]      liste les modeles, ou change de modele
  /systeme [texte]   affiche ou remplace le prompt systeme
  /temperature [x]   temperature (defaut 0.7)
  /limite [n]        num_predict, max de tokens (defaut 900)
  /reset             vide la conversation
  /historique        sort l'historique de la session
  /sortir            quitter`;

async function handle(line) {
  const [cmd, ...rest] = line.trim().split(/\s+/);
  const arg = rest.join(' ').trim();
  switch (cmd) {
    case '/aide': case '/help': console.log(HELP); return true;
    case '/stat': await status(); return true;
    case '/modele': {
      if (!arg) { (await listModels()).forEach((m) => console.log(`  ${m.name}  ${m.size}  ${m.params}`)); return true; }
      state.model = arg;
      console.log(`modele -> ${state.model}`);
      return true;
    }
    case '/systeme':
      if (arg) state.system = arg;
      console.log(state.system ? `systeme : ${state.system}` : 'systeme : (aucun)');
      return true;
    case '/temperature': if (arg) state.temperature = Number(arg); console.log(`temperature = ${state.temperature}`); return true;
    case '/limite': if (arg) state.numPredict = Number(arg); console.log(`num_predict = ${state.numPredict}`); return true;
    case '/reset': state.messages = []; console.log('conversation videe'); return true;
    case '/historique':
      state.messages.forEach((m, i) => console.log(`${String(i).padStart(3)} ${m.role.padEnd(9)} ${m.content.replace(/\n/g, ' ').slice(0, 160)}`));
      return true;
    case '/sortir': case '/exit': case '/quit': return false;
    default:
      if (line.startsWith('/')) { console.log(`commande inconnue : ${cmd} — /aide`); return true; }
      await generate(line);
      return true;
  }
}

(async () => {
  // Mode one-shot : -p "prompt" — pour scripter et tester.
  const oneShot = arg('-p', null);
  if (oneShot) {
    state.quiet = true; // stdout = reponse brute, metrics sur stderr
    console.log(await generate(oneShot));
    process.exit(0);
  }

  console.log(`Hermes — ${BASE} — modele ${state.model}`);
  console.log('Ctrl-D ou /sortir pour quitter, /aide pour la liste des commandes.\n');

  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, prompt: 'hermes> ' });
  let history = [];
  try { history = fs.readFileSync(HISTORY, 'utf8').split('\n').filter(Boolean); } catch {}
  rl.history = history;
  rl.prompt();

  rl.on('line', async (line) => {
    if (!line.trim()) { rl.prompt(); return; }
    try {
      fs.mkdirSync(path.dirname(HISTORY), { recursive: true });
      fs.appendFileSync(HISTORY, line + '\n');
    } catch {}
    try {
      const keep = await handle(line);
      if (!keep) { rl.close(); return; }
    } catch (e) {
      console.log(`\nERREUR : ${e.message}`);
    }
    console.log();
    rl.prompt();
  });
  rl.on('close', () => process.exit(0));
})();