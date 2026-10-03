// Test d integration : le message Telegram rendu par le generateur doit etre
// relisible tel quel par l'approbateur, qui ne stocke rien et reapplique ses
// regex sur le texte du message (cf. WORKPLAN.md §5). Un deplacer de marqueur
// casse l'approbation silencieusement.
const fs = require('fs');
const gen = JSON.parse(fs.readFileSync(__dirname + '/../workflow-telegram-approval.json', 'utf8'));
const app = JSON.parse(fs.readFileSync(__dirname + '/../workflow-biz4a-approver.json', 'utf8'));

const genText = gen.nodes.find((n) => n.name === 'Telegram Approval').parameters.text;
const genInner = genText.replace(/^=\{\{/, '').replace(/\}\}$/, '').trim();
const renderGen = (j) => eval(genInner.replace(/\$json/g, 'j'));

const parseCode = app.nodes.find((n) => n.name === 'Parse Decision').parameters.jsCode;
function runApprover(text, messageId = 4242) {
  const sd = {};
  const $input = {
    first: () => ({
      json: {
        callback_query: {
          id: 'cbq1', data: 'approuver',
          from: { id: 1, username: 'TheHatCoder' },
          message: { message_id: messageId, chat: { id: 5387896782 }, text }
        }
      }
    })
  };
  const $getWorkflowStaticData = () => sd;
  return new Function('$input', '$getWorkflowStaticData', parseCode + '\n')($input, $getWorkflowStaticData)[0].json;
}

const cases = [
  {
    name: 'contenu conforme',
    src: { quality_flags_md: [], theme: 'Innovation Odoo',
           hook_md: 'Decouvrez la plateforme BIZ4A.',
           body_md: 'Une gestion integre evite la ressaisie entre vente et comptabilite.',
           cta_md: 'Identifiez votre premier chantier.',
           total_duration_ms: 23400 },
    expect: { theme: 'Innovation Odoo', hook: 'Decouvrez la plateforme BIZ4A.',
              call_to_action: 'Identifiez votre premier chantier.', qualite: 'ok' }
  },
  {
    name: 'contenu non conforme (bandeau)',
    src: { quality_flags_md: ['chiffre non source (hook : 20)'], theme: 'SuccesStory BIZ4A',
           hook_md: 'J ai reduit les couts de 20 %.',
           body_md: 'Resultat obtenu en 6 mois.',
           cta_md: 'Contactez notre equipe.',
           total_duration_ms: 31000 },
    expect: { theme: 'SuccesStory BIZ4A', hook: 'J ai reduit les couts de 20 %.',
              qualite: 'non_conforme' }
  },
  {
    name: 'champ manquant + marqueurs accentues',
    src: { quality_flags_md: ['champ manquant (body)'], theme: 'Actualite OHADA',
           hook_md: 'Repercussions a resoudre.', body_md: '', cta_md: 'Anticipez vos obligations.',
           total_duration_ms: null },
    expect: { theme: 'Actualite OHADA', hook: 'Repercussions a resoudre.',
              body: '', qualite: 'non_conforme' }
  },
  {
    name: 'markdown echappe (soulignement)',
    src: { quality_flags_md: [], theme: 'Conseil Gestion PME',
           hook_md: 'Un processus _standardise_ et *documenté*.',
           body_md: 'Chaque etape est tracee.', cta_md: 'Adoptez la methode.',
           total_duration_ms: 41000 },
    expect: { theme: 'Conseil Gestion PME', hook: 'Un processus _standardise_ et *documenté*.',
              qualite: 'ok' }
  }
];

let fail = 0;
for (const c of cases) {
  const text = renderGen(c.src);
  let out;
  try { out = runApprover(text); }
  catch (e) { console.log('THROW  ' + c.name + ' :: ' + e.message); fail++; continue; }

  const problems = [];
  for (const [k, v] of Object.entries(c.expect)) {
    // Pas de re-echappement : les champs *_md sont deja echappes par le
    // generateur, et Telegram renvoie le texte tel qu envoye. L'approbateur
    // doit donc restituer exactement la valeur d'entree.
    if (String(v) !== String(out[k])) {
      problems.push(`${k}: attendu ${JSON.stringify(v)}, obtenu ${JSON.stringify(out[k])}`);
    }
  }
  if (problems.length) { fail++; console.log('FAIL  ' + c.name); problems.forEach((p) => console.log('        ' + p)); }
  else console.log('ok   aller-retour ' + c.name);
}
console.log('\n' + (fail ? fail + ' ECHEC(S)' : 'Aller-retour generateur -> approbateur : OK'));
process.exit(fail ? 1 : 0);