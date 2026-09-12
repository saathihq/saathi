// Generated from contract/schema/saathi.json by contract/generate.mjs. Do not edit.
// Run `npm run generate -w contract` after changing the schema.
// Contract version 0.1.0.

export const CONTRACT_VERSION = "0.1.0";
export const DEFAULT_BASE_URL = "https://api.saathi.dev";

/** `~/.saathi/shell.json`. */
export type SaathiConfiguration = {
  /** Overrides the hosted default. */
  backendUrl?: string;
  /** Bearer token for the backend. */
  token?: string;
};

/** How a spoken line should sound. Accessibility-first: the companion says what is happening, and how it says it is part of the message. */
export type Tone = "calm" | "encouraging" | "neutral";
export const TONE_CASES: readonly Tone[] = ["calm", "encouraging", "neutral"] as const;

/** How fast to move through a sequence of steps. The learner sets this, not the model. */
export type Pace = "slow" | "normal";
export const PACE_CASES: readonly Pace[] = ["slow", "normal"] as const;

/** Speak a line to the learner. The companion narrates; this is the primary action. */
export type SayAction = {
  action: "say";
  /** What to say. One or two sentences. */
  text: string;
  /** How it should sound. */
  tone?: Tone;
};

/** Put one step of something being learned in front of the learner, with its place in the whole. */
export type ShowStepAction = {
  action: "show_step";
  /** The step itself, in a few words. */
  title: string;
  /** One sentence of elaboration, if it helps. */
  detail?: string | undefined;
  /** 1-based position of this step. */
  index: number;
  /** How many steps there are, so progress is always audible. */
  total: number;
  /** How fast to move on. */
  pace?: Pace;
};

/** Open a resource in the learner's browser. http(s) only — clients MUST reject every other scheme rather than pass it to the OS. */
export type OpenUrlAction = {
  action: "open_url";
  /** An absolute http or https URL. */
  url: string;
};

/** Every action a Saathi client can be asked to perform. Closed on purpose. */
export type SaathiAction =
  | SayAction
  | ShowStepAction
  | OpenUrlAction;

/** The wire names, in schema order — for building a tool list or a smoke test. */
export const ACTION_WIRE_NAMES = ["say", "show_step", "open_url"] as const;

export const BACKEND_ROUTES = [
  { method: "GET", path: "/health", auth: false },
  { method: "POST", path: "/session", auth: true },
] as const;
