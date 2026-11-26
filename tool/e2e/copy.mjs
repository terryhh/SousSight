// Every piece of app copy the hero journey matches, in one place. Each entry
// accepts the current wording AND the wording before the SS-089 UX pass
// (PR #221), so the journey runs on builds from either side of that change.
// When copy changes again, add the new wording here; don't edit the spec.
//
// Flutter web exposes no widget keys in the DOM, so accessible names are the
// stable handle. (Semantics(identifier:) on these widgets would give the
// journey copy-independent selectors; see README "Integration needed".)

const any = (...alternatives) =>
  new RegExp(alternatives.map((a) => (a instanceof RegExp ? a.source : escape(a))).join('|'));
const exactly = (...alternatives) =>
  new RegExp(`^(${alternatives.map((a) => escape(a)).join('|')})$`);
function escape(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export const COPY = {
  // Pantry screen
  rehearsalBanner: /^(Rehearsal mode|Practice mode \(pretend answers\)) ·/,
  findMeal: exactly('Find my meal'),
  typeIt: exactly('Type it'),
  pantryField: /canned black beans/,
  couldNotConnect: any('Could not connect to your kitchen'),
  pantryResult: any('Your pantry haul'),
  pantryUnavailable: any(
    'Ingredient matching is unavailable',
    "Matching your food didn't work",
    'could not read that answer',
  ),
  simulatedBadge: /simulat|practice mode|pretend/i,
  sourceBadge: /^Where this ran:/,
  cookRecipe: /^Cook Peanut Butter Sandwich/,
  recipeListItem: /^Peanut Butter Sandwich/,

  // Cooking screen
  cookingSpace: any('Your cooking space'),
  recipeTitle: any('Peanut Butter Sandwich'),
  composer: /Ask the coach|Ask Coach Lite|Ask a question|Your answer/,
  send: /Send message/,
  liveCoachNeeded: any('Connect the live coach to talk or type a question'),
  consentDecline: exactly("Don't send"),
  coachBlocked: any(
    /on-device coach (is still downloading|can't|isn't ready|is not available|could not answer)/,
    "can't run the on-device coach",
    'Nothing was sent.',
    "I can't answer",
    'still downloading',
  ),
  watch: /Watch my food/,
  pauseWatch: /Pause watch/,
  cameraPlaceholder: any('Your counter is the canvas'),
  watchRefused: any(
    'Watch needs a real camera connection',
    "can't look at photos",
    'Watch stopped',
    'watch could not start',
    'camera could not start',
    "so I can't watch",
    "isn't ready yet",
    'still downloading',
    'could not start a watch',
  ),

  // Trust surfaces
  ledgerButton: exactly('What was sent', 'What we sent'),
  ledgerHeading: any('What left this device', 'What we sent'),
  onDeviceButton: exactly('On-device AI', 'On this device'),
  onDeviceHeading: exactly('On-device AI', 'On this device'),
};
