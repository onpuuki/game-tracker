import { z } from 'zod';

export const eventSchema = z.object({
  is_valid_event: z.boolean(),
  existing_id: z.string().nullable(),
  match_reason: z.string().nullable(),
  title: z.string(),
  summary: z.string(),
  startDate_raw: z.string().nullable(),
  endDate_raw: z.string().nullable(),
  startDate: z.string().nullable(),
  endDate: z.string().nullable(),
  is_gift_code: z.boolean(),
  redeemCode: z.string().nullable(),
  tag: z.string().nullable(),
  eventUrl: z.string().nullable(),
  rewards: z.array(z.object({
    name: z.string(),
    quantity: z.string()
  })).default([])
});

export const responseSchema = z.object({
  liveness_audit_purges: z.array(z.object({
    doc_id: z.string(),
    purge_type: z.string().optional(),
    purge_reason: z.string()
  })).default([]),
  events: z.array(eventSchema).default([])
});
