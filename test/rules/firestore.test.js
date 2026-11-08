import { readFile } from 'node:fs/promises';
import { after, before, beforeEach, test } from 'node:test';
import { initializeTestEnvironment, assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { Bytes, Timestamp, collection, deleteDoc, doc, getDoc, getDocs, query, setDoc, updateDoc, where } from 'firebase/firestore';

const projectId = 'demo-soussight-rules';
let environment;
const session = (uid = 'cook-a') => ({
  learnerId: uid, recipeId: 'chickpea-wrap', recipeVersion: 1,
  ingredients: { chickpeas: 'have' }, substitutions: [], currentStepId: 'mash',
  completedStepIds: [], revision: 0, createdAt: Timestamp.fromMillis(1000),
  updatedAt: Timestamp.fromMillis(1000), language: 'en', confirmedFacts: [],
});
const db = (uid = 'cook-a', claims = {}) => environment.authenticatedContext(uid, claims).firestore();
const checkpoint = () => ({ sessionId: 'meal', stepId: 'mash', checkpointDefId: 'texture',
  photoJpeg: Bytes.fromUint8Array(new Uint8Array([255, 216, 255])),
  capturedAt: Timestamp.fromMillis(1000), selfRating: 'notSure', sessionRevision: 0,
  learnerConfirmed: false,
});
async function seed(path, data) {
  await environment.withSecurityRulesDisabled(context => setDoc(doc(context.firestore(), path), data));
}

before(async () => {
  if (!process.env.FIRESTORE_EMULATOR_HOST) throw new Error('Run via npm test: a local Firestore emulator is required.');
  const [host, port] = process.env.FIRESTORE_EMULATOR_HOST.split(':');
  if (!['127.0.0.1', 'localhost', '[::1]'].includes(host)) throw new Error('Only a local emulator is allowed.');
  environment = await initializeTestEnvironment({ projectId, firestore: {
    host, port: Number(port), rules: await readFile(new URL('../../firestore.rules', import.meta.url), 'utf8'),
  } });
});
beforeEach(async () => environment.clearFirestore());
after(async () => environment?.cleanup());

test('cook creates, reads, updates timers and facts, and deletes their session', async () => {
  const ref = doc(db(), 'sessions/meal');
  await assertSucceeds(setDoc(ref, session()));
  await assertSucceeds(getDoc(ref));
  await assertSucceeds(updateDoc(ref, { revision: 1, timerDeadline: Timestamp.fromMillis(60000),
    timerLabel: 'Rest', timerId: 'timer-1', confirmedFacts: ['No dairy'], updatedAt: Timestamp.fromMillis(2000) }));
  await assertSucceeds(deleteDoc(ref));
});

test('unauthenticated callers and another cook cannot access a private session', async () => {
  await seed('sessions/meal', session());
  for (const client of [environment.unauthenticatedContext().firestore(), db('cook-b')]) {
    const ref = doc(client, 'sessions/meal');
    await assertFails(getDoc(ref));
    await assertFails(updateDoc(ref, { revision: 1 }));
    await assertFails(deleteDoc(ref));
    await assertFails(setDoc(doc(client, 'sessions/forged'), session()));
  }
});

test('owner-filtered session queries succeed and unrestricted queries fail', async () => {
  await seed('sessions/meal', session());
  await seed('sessions/other', session('cook-b'));
  await assertSucceeds(getDocs(query(collection(db(), 'sessions'), where('learnerId', '==', 'cook-a'))));
  await assertFails(getDocs(collection(db(), 'sessions')));
});

test('ownership, recipe, creation time and revision cannot be corrupted on update', async () => {
  await seed('sessions/meal', { ...session(), revision: 3 });
  const ref = doc(db(), 'sessions/meal');
  for (const patch of [{ learnerId: 'cook-b' }, { recipeId: 'other' }, { recipeVersion: 2 },
    { createdAt: Timestamp.fromMillis(2000) }, { revision: 2 }, { surprise: true }]) {
    await assertFails(updateDoc(ref, patch));
  }
});

test('malformed sessions, invalid ingredient states and nonzero initial revision fail', async () => {
  const ref = doc(db(), 'sessions/meal');
  for (const patch of [{ revision: 1 }, { ingredients: { chickpeas: 'unsafe' } },
    { timerDeadline: 'tomorrow' }, { confirmedFacts: 'fact' }, { language: null },
    { currentStepId: '' }, { recipeVersion: 0 }, { extra: true }]) {
    await assertFails(setDoc(ref, { ...session(), ...patch }));
  }
});

test('checkpoint photos stay private and only assessment/confirmation can change', async () => {
  await seed('sessions/meal', session());
  const ref = doc(db(), 'sessions/meal/checkpoints/photo');
  await assertSucceeds(setDoc(ref, checkpoint()));
  await assertSucceeds(getDoc(ref));
  await assertSucceeds(updateDoc(ref, { learnerConfirmed: true, assessment: { feedback: 'Check texture' } }));
  await assertFails(updateDoc(ref, { photoJpeg: Bytes.fromUint8Array(new Uint8Array([1])) }));
  for (const operation of [getDoc, deleteDoc]) await assertFails(operation(doc(db('cook-b'), ref.path)));
  await assertFails(setDoc(doc(db('cook-b'), 'sessions/meal/checkpoints/forged'), checkpoint()));
  await assertSucceeds(deleteDoc(ref));
});

test('checkpoint parent linkage, rating and photo size are validated', async () => {
  await seed('sessions/meal', session());
  const ref = doc(db(), 'sessions/meal/checkpoints/photo');
  for (const patch of [{ sessionId: 'other' }, { selfRating: 'safe' }, { photoJpeg: 'not-bytes' },
    { photoJpeg: Bytes.fromUint8Array(new Uint8Array(786433)) }]) {
    await assertFails(setDoc(ref, { ...checkpoint(), ...patch }));
  }
  await assertFails(setDoc(doc(db(), 'sessions/missing/checkpoints/photo'), { ...checkpoint(), sessionId: 'missing' }));
});

test('all server ledgers and contacts deny reads and writes even to catalog editors', async () => {
  for (const name of ['_liveTokenLimits', '_dinnerNotifications', '_dinnerMealClaims', '_dinnerSendLimits',
    '_dinnerProviderMessages', 'instructorContacts', 'learnerContacts']) {
    await seed(`${name}/private`, { secret: 'fixture' });
    for (const client of [db(), db('editor', { soussightCatalogEditor: true })]) {
      const ref = doc(client, `${name}/private`);
      await assertFails(getDoc(ref));
      await assertFails(setDoc(ref, { secret: 'changed' }));
      await assertFails(deleteDoc(ref));
    }
  }
});

test('catalog privilege does not grant access to cooking sessions', async () => {
  await seed('sessions/meal', session());
  await assertFails(getDoc(doc(db('editor', { soussightCatalogEditor: true }), 'sessions/meal')));
  await assertFails(getDoc(doc(db('instructor', { email: 'instructor@example.com' }), 'sessions/meal')));
  await assertFails(setDoc(doc(db(), 'recipes/wrap'), { title: 'Wrap' }));
  await assertSucceeds(setDoc(doc(db('editor', { soussightCatalogEditor: true }), 'recipes/wrap'), { title: 'Wrap' }));
  await assertSucceeds(getDoc(doc(db(), 'recipes/wrap')));
});

test('legacy records require owned sessions and never allow client notification data', async () => {
  await seed('sessions/meal', session());
  const request = { learnerId: 'cook-a', sessionId: 'meal', recipeId: 'wrap', stepId: 'mash',
    createdAt: Timestamp.fromMillis(1000), status: 'submitted' };
  const ref = doc(db(), 'requests/question');
  await assertSucceeds(setDoc(ref, request));
  await assertFails(getDoc(doc(db('cook-b'), ref.path)));
  await assertFails(setDoc(doc(db(), 'requests/notify'), { ...request, notify: {} }));
  await assertFails(setDoc(doc(db('cook-b'), 'requests/forged'), { ...request, learnerId: 'cook-b' }));
  await assertFails(updateDoc(ref, { notify: {}, status: 'resolved' }));
  await assertSucceeds(updateDoc(ref, { status: 'resolved' }));
});

test('household message status is readable only by the session owner and never client-writable', async () => {
  await seed('sessions/meal', session());
  const status = { kind: 'ready', status: 'rejected', errorTitle: 'Illegal Sender Address',
    errorCode: '1120', simulated: true, updatedAt: 1000 };
  await seed('sessions/meal/notifications/notice-1', status);
  const ref = doc(db(), 'sessions/meal/notifications/notice-1');
  await assertSucceeds(getDoc(ref));
  // Listening before the server creates the document must also work.
  await assertSucceeds(getDoc(doc(db(), 'sessions/meal/notifications/not-yet')));
  await assertFails(setDoc(ref, { ...status, status: 'delivered' }));
  await assertFails(updateDoc(ref, { status: 'delivered' }));
  await assertFails(deleteDoc(ref));
  await assertFails(setDoc(doc(db(), 'sessions/meal/notifications/forged'), status));
  for (const client of [db('cook-b'), db('editor', { soussightCatalogEditor: true }),
    environment.unauthenticatedContext().firestore()]) {
    await assertFails(getDoc(doc(client, ref.path)));
    await assertFails(setDoc(doc(client, ref.path), status));
  }
  await assertFails(getDoc(doc(db(), 'sessions/missing/notifications/notice-1')));
});
