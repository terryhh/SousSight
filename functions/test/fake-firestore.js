// In-memory Firestore double: serialised transactions, path-string refs.
export function fakeFirestore(seed = [['sessions/meal-1', { learnerId: 'cook-1' }]]) {
  const docs = new Map(seed);
  let queue = Promise.resolve();
  return {
    docs,
    doc: (path) => path,
    collection: (name) => ({ doc: (id) => `${name}/${id}` }),
    runTransaction(callback) {
      const task = queue.then(async () => {
        const writes = [];
        const result = await callback({
          get: async (ref) => ({ exists: docs.has(ref), data: () => docs.get(ref) }),
          create(ref, data) {
            if (docs.has(ref)) throw new Error('Already exists');
            writes.push(() => docs.set(ref, data));
          },
          set(ref, data, options) {
            writes.push(() => docs.set(ref, options?.merge ? { ...docs.get(ref), ...data } : data));
          },
          update(ref, data) { writes.push(() => docs.set(ref, { ...docs.get(ref), ...data })); },
        });
        writes.forEach((write) => write());
        return result;
      });
      queue = task.catch(() => {});
      return task;
    },
  };
}
