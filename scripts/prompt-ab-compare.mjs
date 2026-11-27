#!/usr/bin/env node
/**
 * Zero-dependency Prompt A/B diff comparator and Markdown report generator.
 *
 * Usage:
 *   node scripts/prompt-ab-compare.mjs \
 *     --base-dump base/dump.json --cand-dump cand/dump.json \
 *     --base-jsonl base/l2.jsonl --cand-jsonl cand/l2.jsonl \
 *     [--out report.md] [--strict]
 */

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

export function parseArgs(argv) {
  const opts = { strict: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--strict") {
      opts.strict = true;
    } else if (arg.startsWith("--") && i + 1 < argv.length) {
      opts[arg.slice(2)] = argv[++i];
    } else {
      throw new Error(`Unexpected argument: ${arg}`);
    }
  }
  return opts;
}

export function readJsonl(filePath) {
  const text = fs.readFileSync(filePath, "utf8").trim();
  if (!text) return [];
  return text.split(/\r?\n/).map((line, idx) => {
    try {
      return JSON.parse(line);
    } catch (err) {
      throw new Error(`Invalid JSONL at ${filePath}:${idx + 1}: ${err.message}`);
    }
  });
}

export function compareDumps(baseDump, candDump) {
  const baseByName = new Map((baseDump.variants || []).map((v) => [v.name, v]));
  const candByName = new Map((candDump.variants || []).map((v) => [v.name, v]));
  const names = [...new Set([...baseByName.keys(), ...candByName.keys()])];

  return names.map((name) => {
    const a = baseByName.get(name);
    const b = candByName.get(name);
    const aChars = a?.chars ?? 0;
    const bChars = b?.chars ?? 0;
    const deltaChars = bChars - aChars;
    const pct = aChars > 0 ? (deltaChars / aChars) * 100 : 0;
    const identical = Boolean(a && b && a.sha256 === b.sha256);

    return {
      name,
      baseChars: aChars,
      candChars: bChars,
      deltaChars,
      deltaPct: Number(pct.toFixed(2)),
      baseProse: a?.sections?.prose_chars ?? 0,
      candProse: b?.sections?.prose_chars ?? 0,
      baseTools: a?.sections?.tool_disclosure_chars ?? 0,
      candTools: b?.sections?.tool_disclosure_chars ?? 0,
      baseSkills: a?.sections?.skills_chars ?? 0,
      candSkills: b?.sections?.skills_chars ?? 0,
      identical,
    };
  });
}

function firstToolDivergence(baseCalls = [], candCalls = []) {
  const len = Math.max(baseCalls.length, candCalls.length);
  for (let i = 0; i < len; i++) {
    if (baseCalls[i] !== candCalls[i]) {
      return {
        index: i,
        base: baseCalls[i] ?? "<end>",
        cand: candCalls[i] ?? "<end>",
      };
    }
  }
  return null;
}

function avg(nums) {
  if (nums.length === 0) return 0;
  return nums.reduce((s, n) => s + n, 0) / nums.length;
}

export function compareRuns(baseRows, candRows) {
  const groupKey = (r) => `${r.model || "unknown"}::${r.case}`;
  const baseMap = new Map();
  const candMap = new Map();

  for (const r of baseRows) {
    const k = groupKey(r);
    if (!baseMap.has(k)) baseMap.set(k, []);
    baseMap.get(k).push(r);
  }
  for (const r of candRows) {
    const k = groupKey(r);
    if (!candMap.has(k)) candMap.set(k, []);
    candMap.get(k).push(r);
  }

  const keys = [...new Set([...baseMap.keys(), ...candMap.keys()])].sort();
  const summaries = [];
  let hardRegressions = 0;
  let totalRegressions = 0;

  for (const k of keys) {
    const aList = (baseMap.get(k) || []).sort((x, y) => (x.run ?? 0) - (y.run ?? 0));
    const bList = (candMap.get(k) || []).sort((x, y) => (x.run ?? 0) - (y.run ?? 0));
    const sample = bList[0] || aList[0];
    const aPass = aList.filter((r) => r.pass).length;
    const bPass = bList.filter((r) => r.pass).length;
    const aRate = aList.length ? aPass / aList.length : 0;
    const bRate = bList.length ? bPass / bList.length : 0;

    const pairs = Math.min(aList.length, bList.length);
    let aPassBFail = 0;
    let aFailBPass = 0;
    let bothFail = 0;
    let divergence = null;
    let failedChecks = [];

    for (let i = 0; i < pairs; i++) {
      const a = aList[i];
      const b = bList[i];
      if (a.pass && !b.pass) {
        aPassBFail++;
        if (!divergence) {
          divergence = firstToolDivergence(a.tool_calls, b.tool_calls);
          failedChecks = (b.checks || []).filter((c) => !c.pass).map((c) => c.check);
          if (b.error) failedChecks.push(`error:${b.error}`);
        }
      } else if (!a.pass && b.pass) {
        aFailBPass++;
      } else if (!a.pass && !b.pass) {
        bothFail++;
      }
    }

    const hardGuardrail = Boolean(sample.hard_guardrail);
    const unstableBaseline = aList.length > 0 && aRate < 0.8;
    const hardRegression = hardGuardrail && aList.length > 0 && aPass === aList.length && bPass < bList.length;
    const regression = hardRegression || (!unstableBaseline && bRate < aRate);

    if (hardRegression) hardRegressions++;
    if (regression) totalRegressions++;

    const aPromptTok = avg(aList.map((r) => r.usage?.prompt_tokens ?? 0));
    const bPromptTok = avg(bList.map((r) => r.usage?.prompt_tokens ?? 0));
    const aCachedTok = avg(aList.map((r) => r.usage?.cached_tokens ?? 0));
    const bCachedTok = avg(bList.map((r) => r.usage?.cached_tokens ?? 0));
    const aRounds = avg(aList.map((r) => r.rounds ?? 0));
    const bRounds = avg(bList.map((r) => r.rounds ?? 0));
    const aHelp = avg(aList.map((r) => r.help_calls ?? 0));
    const bHelp = avg(bList.map((r) => r.help_calls ?? 0));

    summaries.push({
      model: sample.model || "unknown",
      caseName: sample.case,
      category: sample.category || "",
      hardGuardrail,
      basePass: aPass,
      baseTotal: aList.length,
      candPass: bPass,
      candTotal: bList.length,
      aPassBFail,
      aFailBPass,
      bothFail,
      unstableBaseline,
      hardRegression,
      regression,
      deltaPromptTokens: Math.round(bPromptTok - aPromptTok),
      deltaCachedTokens: Math.round(bCachedTok - aCachedTok),
      deltaRounds: Number((bRounds - aRounds).toFixed(2)),
      deltaHelpCalls: Number((bHelp - aHelp).toFixed(2)),
      divergence,
      failedChecks,
    });
  }

  return { summaries, hardRegressions, totalRegressions };
}

export function renderMarkdown({ dumpDiff, runDiff }) {
  const lines = ["# Prompt A/B Regression Comparison Report", ""];

  if (dumpDiff && dumpDiff.length > 0) {
    lines.push("## L0 · Static Prompt Matrix Diff", "");
    lines.push("| Variant | Base chars | Cand chars | Δ chars (%) | Δ prose | Δ tools | Δ skills | Byte-identical |");
    lines.push("|---|---:|---:|---:|---:|---:|---:|:---:|");
    for (const d of dumpDiff) {
      const sign = d.deltaChars > 0 ? "+" : "";
      lines.push(
        `| \`${d.name}\` | ${d.baseChars} | ${d.candChars} | ${sign}${d.deltaChars} (${sign}${d.deltaPct}%) | ${d.candProse - d.baseProse} | ${d.candTools - d.baseTools} | ${d.candSkills - d.baseSkills} | ${d.identical ? "yes" : "no"} |`
      );
    }
    lines.push("");
  }

  if (runDiff && runDiff.summaries.length > 0) {
    lines.push("## L1/L2 · Paired Behavior & Cost Diff", "");
    lines.push(
      `- Hard-guardrail regressions: **${runDiff.hardRegressions}** | Total regressions: **${runDiff.totalRegressions}**`
    );
    lines.push("");
    lines.push("| Model | Case | Guard | Base | Cand | A✓B✗ | A✗B✓ | ΔPrompt tok | ΔCached tok | ΔRounds | ΔHelp | Verdict |");
    lines.push("|---|---|:---:|---:|---:|---:|---:|---:|---:|---:|---:|---|");
    for (const s of runDiff.summaries) {
      const verdict = s.hardRegression
        ? "REGRESSION (HARD)"
        : s.regression
          ? "REGRESSION"
          : s.unstableBaseline
            ? "UNSTABLE_BASE"
            : s.aFailBPass > 0
              ? "IMPROVED"
              : "PASS";
      lines.push(
        `| \`${s.model}\` | \`${s.caseName}\` | ${s.hardGuardrail ? "hard" : "std"} | ${s.basePass}/${s.baseTotal} | ${s.candPass}/${s.candTotal} | ${s.aPassBFail} | ${s.aFailBPass} | ${s.deltaPromptTokens} | ${s.deltaCachedTokens} | ${s.deltaRounds} | ${s.deltaHelpCalls} | ${verdict} |`
      );
    }
    lines.push("");

    const regressed = runDiff.summaries.filter((s) => s.aPassBFail > 0);
    if (regressed.length > 0) {
      lines.push("### First Divergence on Regressed Cases", "");
      for (const s of regressed) {
        const div = s.divergence
          ? `step #${s.divergence.index + 1}: base=\`${s.divergence.base}\` vs cand=\`${s.divergence.cand}\``
          : "same tool sequence, output/check mismatch";
        lines.push(`- \`${s.model}\` / \`${s.caseName}\`: ${div}; failed checks: ${s.failedChecks.join(", ")}`);
      }
      lines.push("");
    }
  }

  return lines.join("\n");
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  let dumpDiff = null;
  let runDiff = null;

  if (opts["base-dump"] && opts["cand-dump"]) {
    const baseDump = JSON.parse(fs.readFileSync(opts["base-dump"], "utf8"));
    const candDump = JSON.parse(fs.readFileSync(opts["cand-dump"], "utf8"));
    dumpDiff = compareDumps(baseDump, candDump);
  }

  if (opts["base-jsonl"] && opts["cand-jsonl"]) {
    const baseRows = readJsonl(opts["base-jsonl"]);
    const candRows = readJsonl(opts["cand-jsonl"]);
    runDiff = compareRuns(baseRows, candRows);
  }

  const md = renderMarkdown({ dumpDiff, runDiff });
  if (opts.out) {
    fs.mkdirSync(path.dirname(opts.out), { recursive: true });
    fs.writeFileSync(opts.out, md, "utf8");
  } else {
    process.stdout.write(md);
  }

  if (opts.strict && runDiff && runDiff.hardRegressions > 0) {
    process.exit(1);
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
