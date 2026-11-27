// The ways a book-folding device (an iPhone Duo Simulator) is shown and held, for every client: which of its screens
// shows, how far it opens, how it stands, and what its station is told so the simulator shows that screen the right
// way up. A client draws the device and moves between postures; this says what each one is and what to send.

/** The inputs a posture change sends a view (`devices.sendToScreenView`): the turn, then the hinge's sweep. */
export type ScreenPostureInput =
  | {
      t: "orient";
      degrees: 0 | 90 | 180 | 270;
      screen: "cover" | "inner";
      hinge: number;
    }
  | { t: "hinge"; degrees: number; ms: number };

/** How long a posture's hinge takes to sweep on a device that takes any angle: the clients' own move between postures. */
export const POSTURE_HINGE_MS = 600;

export type ScreenPostureId =
  | "coverPortrait"
  | "coverLandscape"
  | "tent"
  | "laptop"
  | "innerLandscape"
  | "innerPortrait";

export type ScreenPosture = {
  id: ScreenPostureId;
  /** The screen that shows: the cover display outside, or the inner one. */
  screen: "cover" | "inner";
  /** How far it opens, in degrees: 0 closed, 180 flat. */
  opening: number;
  /**
   * How it stands before the viewer: `upright` faces them (turned a quarter for landscape), `tent` stands on its two
   * outer edges with the hinge on top and the cover display toward them, `laptop` lies on one half with the other
   * raised toward them.
   */
  stand: "upright" | "tent" | "laptop";
  /** The screen's picture turned this far from its own upright, as the simulator reports it. */
  orientation: 0 | 90 | 180 | 270;
  /** The fold the station is told: the simulator shows its cover display when closed, the inner one when open. */
  pose: "closed" | "open";
};

/**
 * The cover display is upright with the hinge along its long side; the inner one with the hinge across it. So the inner
 * display is portrait when the hinge lies across the view (laptop, and open portrait) and landscape when the hinge
 * stands up the middle, as a book.
 */
const POSTURES: readonly ScreenPosture[] = [
  {
    id: "coverPortrait",
    screen: "cover",
    opening: 0,
    stand: "upright",
    orientation: 0,
    pose: "closed",
  },
  {
    id: "coverLandscape",
    screen: "cover",
    opening: 0,
    stand: "upright",
    orientation: 90,
    pose: "closed",
  },
  // (60: well inside the angles the simulator shows its cover at; nearer 90 it may keep the inner panel. 90: the cover
  // landscape's own, its hinge on top as a tent's is. Partly open, the simulator stands the cover's UI a half turn from
  // the device, so its station turns the device to keep the picture so, and holds it meanwhile.)
  {
    id: "tent",
    screen: "cover",
    opening: 60,
    stand: "tent",
    orientation: 90,
    pose: "closed",
  },
  // (The inner panel's picture stands a quarter past the device's turn: opened as a book from the cover's portrait, not
  // turned, it is landscape at 90; turned so that the camera half is on top, as a laptop's raised half, at 0.)
  {
    id: "laptop",
    screen: "inner",
    opening: 110,
    stand: "laptop",
    orientation: 0,
    pose: "open",
  },
  {
    id: "innerLandscape",
    screen: "inner",
    opening: 180,
    stand: "upright",
    orientation: 90,
    pose: "open",
  },
  {
    id: "innerPortrait",
    screen: "inner",
    opening: 180,
    stand: "upright",
    orientation: 0,
    pose: "open",
  },
];

/**
 * The postures a device offers: all six for one whose hinge takes any angle (its station's `hinge`: an iPhone Duo
 * Simulator), else none. A foldable that takes only its poses (an Android one) folds by them.
 */
export function screenPosturesOf(hinge: boolean | undefined): ScreenPosture[] {
  return hinge === true ? [...POSTURES] : [];
}

export function screenPostureOf(id: unknown): ScreenPosture | undefined {
  return POSTURES.find((posture) => posture.id === id);
}

/**
 * What brings a device to `posture`: turned straight to the posture's way up on the screen it goes to (one turn, not
 * quarters round the long way), then swept to the posture's opening (a tent's, a laptop's) as a hand folds it, its
 * system animation playing and its apps reading each angle on the way. The turn goes first: the simulator does not take
 * a turn told while it changes panels. It says the opening it goes to, which a tent's cover stands by.
 */
export function screenPostureInputs(posture: ScreenPosture): ScreenPostureInput[] {
  return [
    {
      t: "orient",
      degrees: posture.orientation,
      screen: posture.screen,
      hinge: posture.opening,
    },
    { t: "hinge", degrees: posture.opening, ms: POSTURE_HINGE_MS },
  ];
}
