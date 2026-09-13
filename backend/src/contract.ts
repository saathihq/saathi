// Generated from contract/schema/saathi.json by contract/generate.mjs. Do not edit.
// Run `npm run generate -w contract` after changing the schema.
// Contract version 0.3.0.

export const CONTRACT_VERSION = "0.3.0";
export const DEFAULT_BASE_URL = "https://api.saathi.dev";

/** `~/.saathi/shell.json`. */
export type SaathiConfiguration = {
  /** Which mode to run in. Unset means local — see providers.default. */
  provider?: ProviderKind;
  /** Overrides the provider's default base URL (another Ollama host, a proxy, a compatible server). */
  providerBaseUrl?: string;
  /** Overrides the provider's default model. */
  model?: string;
  /** Your own provider key, for the openai and anthropic modes. Never sent to Saathi's servers. */
  apiKey?: string;
  /** Overrides the hosted backend URL. Only used in hosted mode. */
  backendUrl?: string;
  /** Account token for the hosted backend. Only used in hosted mode. */
  token?: string;
};

/** One row per provider mode: where it runs, what it needs, and whether using it means
 *  anything the learner says leaves their machine. */
export type SaathiProvider = {
  kind: ProviderKind;
  defaultBaseUrl: string;
  defaultModel: string;
  requiresKey: boolean;
  requiresToken: boolean;
  sendsDataOffMachine: boolean;
  keyHeader: string;
  keyPrefix: string;
  summary: string;
};

export const DEFAULT_PROVIDER: ProviderKind = "local";
export const PROVIDERS: readonly SaathiProvider[] = [
  { kind: "local", defaultBaseUrl: "http://localhost:11434", defaultModel: "llama3.2", requiresKey: false, requiresToken: false, sendsDataOffMachine: false, keyHeader: "", keyPrefix: "", summary: "An OpenAI-compatible server on this machine — Ollama, LM Studio, llama.cpp. No key, no account, nothing leaves the device." },
  { kind: "openai", defaultBaseUrl: "https://api.openai.com/v1", defaultModel: "gpt-4o-mini", requiresKey: true, requiresToken: false, sendsDataOffMachine: true, keyHeader: "Authorization", keyPrefix: "Bearer ", summary: "Your own OpenAI key, held on your machine and sent straight to OpenAI. Saathi's servers are not involved." },
  { kind: "anthropic", defaultBaseUrl: "https://api.anthropic.com", defaultModel: "claude-sonnet-5", requiresKey: true, requiresToken: false, sendsDataOffMachine: true, keyHeader: "x-api-key", keyPrefix: "", summary: "Your own Anthropic key, held on your machine and sent straight to Anthropic. Saathi's servers are not involved." },
  { kind: "sarvam", defaultBaseUrl: "https://api.sarvam.ai/v1", defaultModel: "sarvam-105b", requiresKey: true, requiresToken: false, sendsDataOffMachine: true, keyHeader: "Authorization", keyPrefix: "Bearer ", summary: "Your own Sarvam AI key, sent straight to Sarvam. Indian-built models with real Indic-language coverage — the reason this option exists, given where Saathi starts." },
  { kind: "hosted", defaultBaseUrl: "https://api.saathi.dev", defaultModel: "", requiresKey: false, requiresToken: true, sendsDataOffMachine: true, keyHeader: "Authorization", keyPrefix: "Bearer ", summary: "Saathi's hosted backend holds the provider keys; you hold an account token. For people who would rather not run or configure anything." },
] as const;

/** Where the model actually runs. This is the choice that decides whether anything the learner says leaves their machine. */
export type ProviderKind = "local" | "openai" | "anthropic" | "sarvam" | "hosted";
export const PROVIDERKIND_CASES: readonly ProviderKind[] = ["local", "openai", "anthropic", "sarvam", "hosted"] as const;

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
