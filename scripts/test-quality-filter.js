// Harness: execute le vrai jsCode du noeud Parse Content contre des cas connus.
const fs = require('fs');
const wf = JSON.parse(fs.readFileSync(__dirname + '/../workflow-telegram-approval.json', 'utf8'));
const node = wf.nodes.find((n) => n.name === 'Parse Content');
const code = node.parameters.jsCode;

function run(llmResponse, theme, done_reason) {
  const $input = { first: () => ({ json: { response: llmResponse, model: 'llama3.2:3b', done_reason: done_reason || 'stop', total_duration: 23000000000 } }) };
  const $ = () => ({ first: () => ({ json: { theme } }) });
  const f = new Function('$input', '$', code + '\n');
  return f($input, $)[0].json;
}

const cases = [
  // --- reels ecarts du WORKPLAN section 2 : DOIVENT etre bloques ---
  { name: 'WORKPLAN #37 :reduction 20% + 25%', theme: 'SuccesStory BIZ4A', expect: 'BLOCK',
    r: { hook: "J'ai reduit les couts de personnel de 20 % et augmente la productivite de 25 % en 6 mois.",
         body: "Resultat obtenue en seulement 6 mois avec BIZ4A. Les chiffres parlent d eux-memes.",
         call_to_action: "Ma methode est ouverte : echangeons." } },
  { name: 'WORKPLAN #37 :je/mon', theme: 'SuccesStory BIZ4A', expect: 'BLOCK',
    r: { hook: "Je vais vous partager mon experience de reussite avec BIZ4A.",
         body: "Mon approche est simple et mon resultat est verifiable.",
         call_to_action: "Contactez notre equipe." } },
  { name: 'WORKPLAN #37 :en tant que dirigeant', theme: 'Conseil Gestion PME', expect: 'BLOCK',
    r: { hook: "En tant que dirigeant de PME, j'ai realise que la cle du succes reside dans la visibilite.",
         body: "Nous avons automatise nos process chez nous.",
         call_to_action: "Notre solution vous accompagne." } },

  // --- variations ---
  { name: 'notre/nos/nous : BIZ4A parle de lui, legitime', theme: 'Innovation Odoo', expect: 'PASS',
    r: { hook: "Notre solution Odoo repond a nos contraintes.", body: "Nous gagneons du temps de saisie.",
         call_to_action: "Notre equipe vous accompagne." } },
  { name: 'nous + chiffre invente -> bloque', theme: 'Innovation Odoo', expect: 'BLOCK',
    r: { hook: "Notre solution Odoo repond a nos contraintes.", body: "Nous gagnons 25 % de productivite.",
         call_to_action: "Decouvrez notre offre." } },
  { name: 'chiffre libre sans %', theme: 'Actualite OHADA', expect: 'BLOCK',
    r: { hook: "Le nouveau code OHADA entre en vigueur le 1 janvier.", body: "Les entreprises doivent s adapter sous 90 jours.",
         call_to_action: "Anticipez vos obligations." } },
  { name: 'chiffre colle a un mot (marque BIZ4A / Odoo19) -> PAS un chiffre', theme: 'Innovation Odoo', expect: 'PASS',
    r: { hook: "BIZ4A et Odoo19 repondent a un meme besoin de clarte.",
         body: "Une outil integre evite la ressaisie entre la vente et la comptabilite. BIZ4A centralise la donnee.",
         call_to_action: "Decouvrez la plateforme BIZ4A." } },
  { name: 'en tant que ... vous : 2e personne, legitime', theme: 'Innovation Odoo', expect: 'PASS',
    r: { hook: "En tant que dirigeant de PME africaine, vous connaissez les defis du marche.",
         body: "Innover sans ressources impose de choisir ses priorites. Un outil adapte clarifie le chemin.",
         call_to_action: "Identifiez le premier chantier a automatiser." } },
  { name: 'j apostrophe curly', theme: 'Conseil Gestion PME', expect: 'BLOCK',
    r: { hook: "J\u2019ai trompe pendant des mois.", body: "Mieux vaut s informer tot.",
         call_to_action: "Commencez par un audit." } },

  // --- DOIVENT PASSER (faux positifs a surveiller) ---
  { name: 'OK : tiers personne, aucun chiffre', theme: 'Conseil Gestion PME', expect: 'PASS',
    r: { hook: "Beaucoup de PME perdent du temps sur des saisies repetees.",
         body: "Centraliser les donnees rend la vision financiere plus fiable. Un outil adaptes evite les ressaisies et clarifie les priorites.",
         call_to_action: "Evaluez les taches a automatiser dans votre societe." } },
  { name: 'OK : mots contenant je/ma/mes', theme: 'Innovation Odoo', expect: 'PASS',
    r: { hook: "Jeunesse des equipes, managers, monuments : la meme erreur de cadrage.",
         body: "Une demo mal preparee disperse l attention. Meme processus, meme.duration.",
         call_to_action: "Structurez votre demonstration avant le rendez-vous." } },
  { name: 'OK : incomplete -> complete=false', theme: 'Actualite OHADA', expect: 'INCOMPLETE',
    r: { hook: "Le OHADA evolves.", body: "", call_to_action: "Mettez a jour vos procedures." } }
];

let fail = 0;
for (const c of cases) {
  let out;
  try { out = run(JSON.stringify(c.r), c.theme); }
  catch (e) { console.log('THROW  ' + c.name + ' :: ' + e.message); fail++; continue; }

  const flags = out.quality_flags || [];
  let verdict;
  if (c.expect === 'PASS') verdict = out.complete ? 'PASS' : 'WRONGLY BLOCKED';
  else if (c.expect === 'INCOMPLETE') verdict = out.complete ? 'WRONGLY COMPLETE' : 'PASS';
  else verdict = !out.complete ? 'BLOCK' : 'WRONGLY ALLOWED';

  const ok = (verdict === 'PASS' || verdict === 'BLOCK');
  if (!ok) fail++;
  console.log((ok ? 'ok   ' : 'FAIL ') + verdict.padEnd(18) + '| complete=' + String(out.complete).padEnd(5) +
              '| ' + c.name + (flags.length ? '\n       flags: ' + flags.join(' | ') : ''));
}
console.log('\n' + (fail ? fail + ' ECHEC(S)' : 'Tous les cas passent'));
process.exit(fail ? 1 : 0);