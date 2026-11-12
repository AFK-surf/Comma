// What Salix says for the mesh, as a state with no effects: a new connection (`connected`), a word on it (`heard`), and
// the end on purpose (`ended`). Each returns the next state and whom to tell what. A word's number says the order Salix
// read its facts in, on one connection; an older number changes nothing. No word, however new, turns the mesh on where
// the app's own setting has not asked. A credential's expiry is not here: each is judged by itself (device-mesh.ts).

export type MeshTurn<S> = {
  /// The connection words are heard from.
  current: S | null;
  /// The highest number heard on it.
  seq: number;
  /// The connection whose facts stand for this Group, gone or not: a later "no one" takes them back at once too.
  told: S | null;
};

export type MeshTell<S> = { via: S; facts: unknown };
export type MeshStep<S> = { state: MeshTurn<S>; tell: MeshTell<S>[] };

export const noMeshTurn = <S>(): MeshTurn<S> => ({ current: null, seq: -1, told: null });

/// A new connection: its numbers start over. What the last one told stands until the new one says otherwise.
export function meshConnected<S>(state: MeshTurn<S>, socket: S): MeshStep<S> {
  return { state: { ...state, current: socket, seq: -1 }, tell: [] };
}

/// A word from Salix on `socket`, `facts` null when it admits no one.
export function meshHeard<S>(state: MeshTurn<S>, word: { socket: S; seq: number; facts: unknown }, enabled: boolean): MeshStep<S> {
  if (!enabled) return meshEnded(state);
  if (word.socket !== state.current || word.seq <= state.seq) return { state, tell: [] };
  const next = { ...state, seq: word.seq };
  if (word.facts) return { state: { ...next, told: word.socket }, tell: [{ via: word.socket, facts: word.facts }] };
  const earlier = state.told !== null && state.told !== word.socket ? [{ via: state.told, facts: null }] : [];
  return { state: { ...next, told: null }, tell: [...earlier, { via: word.socket, facts: null }] };
}

/// Ended on purpose (signed out, the setting turned off): what was told is taken back at once.
export function meshEnded<S>(state: MeshTurn<S>): MeshStep<S> {
  return { state: { ...state, told: null }, tell: state.told === null ? [] : [{ via: state.told, facts: null }] };
}
