'use strict';
// Timing math: which frame shows at a given time (port of Swift's Playback). tick = 1/fps seconds.

function tickStarts(frames) {
  const out = [];
  let t = 0;
  for (const f of frames) {
    out.push(t);
    t += Math.max(1, f.hold);
  }
  return out;
}

function totalTicks(frames) {
  return frames.reduce((n, f) => n + Math.max(1, f.hold), 0);
}

/** The frame on screen at `tick`. The animation loops, so any tick works (even negative ones). */
function frameIndexAtTick(tick, frames) {
  const total = totalTicks(frames);
  if (total <= 0) return 0;
  const t = ((tick % total) + total) % total;
  let acc = 0;
  for (let i = 0; i < frames.length; i++) {
    acc += Math.max(1, frames[i].hold);
    if (t < acc) return i;
  }
  return frames.length - 1;
}

function tickAtTime(time, fps) {
  return Math.floor(Math.max(0, time) * Math.max(1, fps) + 1e-9);
}

function frameIndexAtTime(time, project) {
  return frameIndexAtTick(tickAtTime(time, project.fps), project.frames);
}

/** When frame `index` first appears, in seconds. */
function timeOfFrame(index, project) {
  const starts = tickStarts(project.frames);
  if (index < 0 || index >= starts.length) return 0;
  return starts[index] / Math.max(1, project.fps);
}

/** Ticks to render for an export that plays `repeats` times and is at least `minimumSeconds` long. */
function exportTicks(project, repeats, minimumSeconds = 0) {
  const once = Math.max(1, totalTicks(project.frames));
  const base = once * Math.max(1, repeats);
  const minTicks = Math.ceil(minimumSeconds * project.fps);
  if (minTicks > base) return Math.ceil(minTicks / once) * once;
  return base;
}

module.exports = { tickStarts, totalTicks, frameIndexAtTick, tickAtTime, frameIndexAtTime, timeOfFrame, exportTicks };
