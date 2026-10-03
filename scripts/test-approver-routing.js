// Test de routage de BIZ4A_Content_Approver, qui sert maintenant DEUX fonctions :
// l'approbation (callback_query) et le chat Hermes (message).
//
// Risque couvert : un chat mal route ne doit NI casser l'approbation
// (WORKPLAN §8.1 : un noeud destructeur fait partir l'IF sur la mauvaise
// branche) NI declencher une generation Ollama pour un message ecarte.
const fs = require('fs');
const wf = JSON.parse(fs.readFileSync(__dirname + '/../workflow-biz4a-approver.json', 'utf8'));
const js = (n) => wf.nodes.find((x) => x.name === n).parameters.jsCode;

function guard(input) {
  const $input = { first: () => ({ json: input }) };
  return new Function('$input', js('Guard Chat') + '\n')($input)[0].json;
}
// Reproduit la chaine REELLE : Reponse Hermes relit chat_id chez 'Guard Chat'.
// La version precedente injectait __chat_id a la main, ce qui masquait le fait
// que le noeud HTTP efface la charge utile et que chat_id arrivait vide.
// Les 23 s d'appel a Ollama ne sont pas simulees : c'est la sortie du noeud HTTP
// qui est injectee, et c'est exactement elle qui perdait chat_id.
let guardOutput = {};
function reponse(httpOutput) {
  const $input = { first: () => ({ json: httpOutput }) };
  const $ = (name) => {
    if (name !== 'Guard Chat') throw new Error('reference inattendue : ' + name);
    return { first: () => ({ json: guardOutput }) };
  };
  return new Function('$input', '$', js('Reponse Hermes') + '\n')($input, $)[0].json;
}

// Reproduit la condition du IF "Message pertinent ?" : ignore == false -> pertinent
const pertinent = (g) => g.ignore === false;

const ALLOWED = '5387896782';
const msg = (chat, text, opts = {}) => ({
  message: {
    message_id: 1, chat: { id: chat }, text,
    from: { id: 1, username: 'TheHatCoder', is_bot: !!opts.isBot }
  }
});

const cases = [
  { name: 'message normal de TON chat -> modele', input: msg(ALLOWED, 'bonjour'),
    expect: { pertinent: true, chat: ALLOWED, text: 'bonjour' } },
  { name: 'chat NON autorise -> ecarte, PAS de generation', input: msg('999', 'bonjour'),
    expect: { pertinent: false } },
  { name: 'message d un bot -> ecarte (pas de boucle)', input: msg(ALLOWED, 'x', { isBot: true }),
    expect: { pertinent: false } },
  { name: 'commande /start -> ecarte', input: msg(ALLOWED, '/start'),
    expect: { pertinent: false } },
  { name: 'media sans texte -> ecarte', input: { message: { message_id: 2, chat: { id: ALLOWED }, from: { id: 1 } } },
    expect: { pertinent: false } },
];

let fail = 0;
for (const c of cases) {
  guardOutput = guard(c.input);
  const g = guardOutput;
  const p = pertinent(g);
  const ok = p === c.expect.pertinent
    && (c.expect.pertinent === false || (String(g.chat_id) === c.expect.chat && g.text === c.expect.text));
  if (!ok) fail++;
  console.log((ok ? 'ok   ' : 'FAIL ') + (p ? 'PERTINENT' : 'ECARTE   ') + ' | ' + c.name
    + (ok ? '' : '  -> ' + JSON.stringify(g)));
}

// La reponse doit etre bornee : Telegram refuse au-dela de 4096.
guardOutput = guard(msg(ALLOWED, 'q'));
const long = reponse({ message: { content: 'x'.repeat(9000) }, total_duration: 23000000000 });
const okLen = long.answer.length < 4096 && long.tronque === true;
console.log((okLen ? 'ok   ' : 'FAIL ') + 'reponse de 9000 car. bornee a ' + long.answer.length + ' (tronque=' + long.tronque + ')');
if (!okLen) fail++;

const court = reponse({ message: { content: 'salut' } });
const okShort = court.answer === 'salut' && court.tronque === false && court.chat_id === ALLOWED;
console.log((okShort ? 'ok   ' : 'FAIL ') + 'reponse courte conservee telle quelle, chat_id transporte');
if (!okShort) fail++;

const vide = (() => { try { reponse({ message: { content: '' } }); return false; } catch { return true; } })();
console.log((vide ? 'ok   ' : 'FAIL ') + 'reponse vide du modele -> erreur explicite, pas de message muet');
if (!vide) fail++;

// Cas qui avait produit "Bad Request: chat_id is empty" en production.
guardOutput = { ignore: false, chat_id: '', text: 'q' };
const noChat = (() => { try { reponse({ message: { content: 'salut' } }); return false; } catch (e) { return /chat_id/.test(e.message); } })();
console.log((noChat ? 'ok   ' : 'FAIL ') + 'chat_id vide en amont -> erreur explicite, pas un envoi muet');
if (!noChat) fail++;

console.log('\n' + (fail ? fail + ' ECHEC(S)' : 'Routage approbation/chat : OK'));
process.exit(fail ? 1 : 0);