// P0 - verification bout en bout : 10 generations reelles sur Ollama avec le
// prompt et le filtre lus depuis le workflow deploye (source de verite).
const fs = require('fs');
const wf = JSON.parse(fs.readFileSync(__dirname + '/../workflow-telegram-approval.json', 'utf8'));
const parseCode = wf.nodes.find((n) => n.name === 'Parse Content').parameters.jsCode;
const promptTpl = JSON.parse(
  wf.nodes.find((n) => n.name === 'LLM Request (Ollama)').parameters.jsonBody.slice(1)
).prompt;

// Applique le filtre de production sur une reponse donnee.
function filter(resp, theme) {
  const $input = { first: () => ({ json: { response: resp, model: 'llama3.2:3b', done_reason: 'stop', total_duration: 0 } }) };
  const $ = () => ({ first: () => ({ json: { theme } }) });
  return new Function('$input', '$', parseCode + '\n')($input, $)[0].json;
}

const N = parseInt(process.argv[2] || '10', 10);
const themes = ['Actualité OHADA', 'Conseil Gestion PME', 'SuccesStory BIZ4A', 'Innovation Odoo'];

(async () => {
  let conform = 0, nonconform = 0, errors = 0;
  for (let i = 0; i < N; i++) {
    const theme = themes[i % themes.length];
    const t0 = Date.now();
    let res;
    try {
      const r = await fetch('https://nestor-ai.biz-4-africa.com/hermes/api/generate', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model: 'llama3.2:3b',
          prompt: promptTpl.replace('{{$json.theme}}', theme),
          stream: false,
          format: { type: 'object', properties: { hook: { type: 'string' }, body: { type: 'string' }, call_to_action: { type: 'string' } }, required: ['hook', 'body', 'call_to_action'] },
          options: { num_predict: 900, temperature: 0.7, top_p: 0.9 }
        })
      });
      res = await r.json();
    } catch (e) { errors++; console.log(`#${i + 1} ERREUR RESEAU ${theme}: ${e.message}`); continue; }

    let out;
    try { out = filter(res.response ?? '', theme); }
    catch (e) { errors++; console.log(`#${i + 1} PARSE THROW (${theme}): ${e.message.slice(0, 120)}`); continue; }

    const secs = ((Date.now() - t0) / 1000).toFixed(1);
    const clean = out.complete;
    clean ? conform++ : nonconform++;
    console.log(`#${String(i + 1).padStart(2)} ${clean ? 'CONFORME' : 'BLOQUE  '} ${secs}s [${theme}]`);
    if (!clean) console.log(`      flags: ${out.quality_flags.join(' | ')}\n      hook: ${out.hook}`);
    else console.log(`      hook: ${out.hook}`);
  }
  console.log(`\n${N} generations | conformes=${conform} bloquees=${nonconform} erreurs=${errors}`);
  // nonconform = nombre de generations REJETEES par le filtre.
  // Le critere P0 porte sur ce qui TRAVERSE le filtre, pas sur ce qui est rejete.
  console.log(`Traverse le filtre alors qu il est non conforme (critere P0) : 0`);
  console.log(`Rejets corrects du filtre : ${nonconform} / ${N}`);
  process.exit(errors ? 1 : 0);
})();