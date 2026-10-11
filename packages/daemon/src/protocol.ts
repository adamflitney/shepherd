import type { CreateRequest } from "./manager.ts";

/** Newline-delimited JSON over a unix socket. */
export interface Request {
  id: number;
  method: string;
  params?: Record<string, unknown>;
}

export type Response = { id: number; result: unknown } | { id: number; error: string };

export interface EventMessage {
  event: string;
  [key: string]: unknown;
}

export type { CreateRequest };
