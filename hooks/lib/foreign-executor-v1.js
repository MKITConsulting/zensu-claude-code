"use strict";

const ZENSU_SKILL = /(?:^|[^A-Za-z0-9_])zensu:[a-z]/i;
const SKILL_NAME = /(^|[^A-Za-z0-9_.:\/@-])(\/?)([a-z][a-z0-9_-]{0,63}):([a-z][a-z0-9_-]{0,63})(?![A-Za-z0-9_:\/@-])/g;
const FENCE = /^(?:\s*(?:>|[-*+]|\d+[.)]))*\s*(`{3,}|~{3,})(.*)$/;
const INLINE_CODE = /(?<!`)(`+)(?!`)[\s\S]*?(?<!`)\1(?!`)/g;
const QUOTED = /"[^"]*"|\u201c[^\u201d]*\u201d|\u2018[^\u2019]*\u2019/g;
const SUB_SKILL_HEADER = /REQUIRED SUB-SKILL/i;
const EXECUTE_VERB = /\b(?:execut|implement)/i;
const PLAN_OBJECT = /\b(?:this|the)\s+plan\b/i;
const NEGATION = /\b(?:not|cannot|never|no|nor|without|instead|avoid|rather|except|unless)\b|n['\u2019]t\b/i;
const SKILL_WORD = /skill/i;
const INVOKING_LEAD = /\b(?:use|using|via|with|invoke|run)\s+(?:the\s+)?$/i;

const foreignExecutor = (plan) => {
  if (typeof plan !== "string" || ZENSU_SKILL.test(plan)) return "";
  let fence = "";
  for (const row of plan.split(/\r?\n/)) {
    const marker = FENCE.exec(row);
    if (fence) {
      if (marker && marker[1][0] === fence[0] && marker[1].length >= fence.length && !marker[2].trim()) fence = "";
      continue;
    }
    if (marker && !(marker[1][0] === "`" && marker[2].includes("`"))) {
      fence = marker[1];
      continue;
    }
    const line = row.replace(INLINE_CODE, " ").replace(QUOTED, " ");
    const carries = SUB_SKILL_HEADER.test(line) || (EXECUTE_VERB.test(line) && PLAN_OBJECT.test(line));
    if (!carries || NEGATION.test(line)) continue;
    for (const match of line.matchAll(SKILL_NAME)) {
      const lead = line.slice(0, match.index + match[1].length);
      if (match[2] === "/" || (SKILL_WORD.test(line) && INVOKING_LEAD.test(lead))) return `${match[3]}:${match[4]}`;
    }
  }
  return "";
};

const noticeText = (executor) => [
  `Zensu delivery route: the approved plan names its own executor, ${executor}, so Zensu asks no delivery-route question for it.`,
  "Carry the plan out the way it says, with the executor it names.",
  `Open your reply with one short line saying that Zensu asked no route question because the plan names ${executor}, and that /zensu:build runs this plan under the Zensu workflow, with its evidence audits and review chain, instead.`,
  "The user's own approval message still wins when it asks for a route rather than only naming one, and a route it refuses is never taken:",
  "/zensu:build or the Zensu workflow runs skill='zensu:build' with the approved plan content as the feature specification,",
  "/zensu:autopilot runs skill='zensu:autopilot' with that content as the feature description,",
  "and /zensu:pilot runs skill='zensu:pilot' naming the tracked feature the plan belongs to.",
].join(" ");

const noticeForPayload = (payload, reader) => {
  try {
    if (!payload || typeof payload !== "object" || payload.tool_name !== "ExitPlanMode") return "";
    if (!reader || typeof reader.responseOrigin !== "function" || typeof reader.resolveApprovedPlan !== "function"
      || !Array.isArray(reader.SOURCES) || !reader.SOURCES.length) return "";
    const origin = reader.responseOrigin(payload);
    if (!origin || origin.ok !== true) return "";
    const resolved = reader.resolveApprovedPlan(payload, reader.SOURCES);
    if (!resolved || resolved.ok !== true) return "";
    const executor = foreignExecutor(resolved.plan);
    return executor ? noticeText(executor) : "";
  } catch (_) {
    return "";
  }
};

module.exports = { foreignExecutor, noticeText, noticeForPayload };
