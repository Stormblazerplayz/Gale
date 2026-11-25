"""A tiny language for writing Gale lessons, plus checks that mirror the Swift engine.

The Swift tests are the final word (every drawing step must pass with its own guide and fail
with a scribble). These Python mirrors catch problems early while the courses are generated.
"""
import math
import random

from learn_geo import ASPECT, dist, resample, seg_dist, simplify, length

DEFAULT_WIDTH = 0.012
SIMPLIFY_TOL = 0.0005
ACCURACY_SLACK = 1.25
MAX_INK_RATIO = 2.5


# ---------------------------------------------------------------- guide data

def _flat(pts, closed):
    pts = list(pts)
    if closed and len(pts) > 2 and dist(pts[0], pts[-1]) < 1e-9:
        pts = pts[:-1]
    if len(pts) > 2:
        if closed:
            # Simplify as a loop: keep the first point fixed by simplifying the closed ring.
            ring = simplify(pts + [pts[0]], SIMPLIFY_TOL)[:-1]
            pts = ring if len(ring) >= 3 else pts
        else:
            pts = simplify(pts, SIMPLIFY_TOL)
    out = []
    for x, y in pts:
        out.append(round(x, 3) + 0.0)
        out.append(round(y, 3) + 0.0)
    return out


def P(pts, role="ink", w=None, closed=False):
    d = {"pts": _flat(pts, closed)}
    if role != "ink":
        d["role"] = role
    if w is not None and abs(w - DEFAULT_WIDTH) > 1e-9:
        d["w"] = w
    if closed:
        d["closed"] = True
    return d


def ink(pts, w=None, closed=False):
    return P(pts, "ink", w, closed)


def helper(pts, w=0.006, closed=False):
    """Construction / helper line (dashed, not scored)."""
    return P(pts, "guide", w, closed)


def accent(pts, w=0.008, closed=False):
    """Highlight line (motion paths, arcs), not scored."""
    return P(pts, "accent", w, closed)


def F(paths, hold=1, notes=None):
    d = {"paths": [p for p in paths if p is not None]}
    if hold != 1:
        d["hold"] = hold
    if notes:
        d["notes"] = [{"text": t, "x": round(x, 3), "y": round(y, 3)} for t, x, y in notes]
    return d


def G(frames, fps=12, loop=True, bg=None, aspect=ASPECT, track=None):
    d = {"aspect": round(aspect, 6), "fps": fps, "loop": loop, "frames": frames}
    if bg:
        d["background"] = bg
    if track:
        assert len(track) == len(frames), ("track needs one point per frame", len(track), len(frames))
        d["track"] = [round(v, 4) + 0.0 for p in track for v in p]
    return d


def still(paths, bg=None, notes=None):
    return G([F(paths, notes=notes)], loop=False, bg=bg)


# ---------------------------------------------------------------- steps

def read(title, text, guide=None):
    s = {"kind": "read", "title": title, "text": text}
    if guide is not None:
        s["guide"] = guide
    return s


def chk_trace(coverage=0.7, accuracy=0.7, tolerance=0.05):
    return {"type": "trace", "coverage": coverage, "accuracy": accuracy, "tolerance": tolerance}


def chk_straight(v=0.06):
    return {"type": "straight", "value": v}


def chk_closed(v=0.06):
    return {"type": "closed", "value": v}


def chk_smooth(v=0.35):
    return {"type": "smooth", "value": v}


def chk_frames(n):
    return {"type": "frameCount", "min": n, "max": n}


def chk_spacing(kind):
    return {"type": "spacing", "spacing": kind}


def chk_loop(v=2.0):
    return {"type": "loop", "value": v}


def trace(title, text, paths, hint=None, checks=(), bg=None, notes=None, coverage=0.7, accuracy=0.7, tolerance=0.05):
    s = {"kind": "trace", "title": title, "text": text,
         "guide": still(paths, bg=bg, notes=notes),
         "checks": [chk_trace(coverage, accuracy, tolerance)] + list(checks)}
    if hint:
        s["hint"] = hint
    return s


def frames(title, text, frame_list, hint=None, checks=(), bg=None, fps=8, coverage=0.7, accuracy=0.7, tolerance=0.05, loop=True):
    n = len(frame_list)
    s = {"kind": "frames", "title": title, "text": text,
         "guide": G(frame_list, fps=fps, loop=loop, bg=bg),
         "checks": [chk_trace(coverage, accuracy, tolerance), chk_frames(n)] + list(checks)}
    if hint:
        s["hint"] = hint
    return s


def quiz(question, choices, answer, explain, guide=None, title="Quick quiz"):
    s = {"kind": "quiz", "title": title, "text": "",
         "quiz": {"question": question, "choices": choices, "answer": answer, "explain": explain}}
    if guide is not None:
        s["guide"] = guide
    return s


def tool(title, text, tool_name, tasks, guide=None):
    s = {"kind": "tool", "title": title, "text": text, "tool": {"tool": tool_name, "tasks": tasks}}
    if guide is not None:
        s["guide"] = guide
    return s


def beat(say, frm, to=None, show=()):
    """One spoken moment of a watch step: the words, the frames that play, and the overlays laid on top
    ("onion", "trail", "chart", "slow")."""
    b = {"say": say, "from": frm, "to": frm if to is None else to}
    if show:
        b["show"] = list(show)
    return b


def watch(title, text, guide, beats):
    """Watch and listen: the narrator says each beat while its frames play."""
    return {"kind": "watch", "title": title, "text": text, "guide": guide, "beats": list(beats)}


def animate(title, text, frame_list, hint=None, checks=(), bg=None, fps=12, coverage=0.7, accuracy=0.7,
            tolerance=0.05, loop=True, say=None):
    """Animate it for real: the frames open in Gale's editor on a locked guide layer."""
    n = len(frame_list)
    s = {"kind": "animate", "title": title, "text": text,
         "guide": G(frame_list, fps=fps, loop=loop, bg=bg),
         "checks": [chk_trace(coverage, accuracy, tolerance), chk_frames(n)] + list(checks)}
    if hint:
        s["hint"] = hint
    if say:
        s["say"] = list(say)
    return s


MINUTES = {"read": 0.6, "trace": 1.0, "frames": 3.0, "quiz": 0.5, "tool": 2.0, "watch": 1.0, "animate": 5.0}


def lesson(lid, title, summary, steps):
    for i, s in enumerate(steps):
        s["id"] = "s%d" % (i + 1)
    ordered = [{k: s[k] for k in ("id", "kind", "title", "text", "hint", "guide", "checks", "quiz", "tool", "say", "beats")
                if k in s}
               for s in steps]
    minutes = max(2, int(math.ceil(sum(MINUTES[s["kind"]] for s in steps))))
    return {"id": lid, "title": title, "summary": summary, "minutes": minutes, "steps": ordered}


def course(cid, track, title, subtitle, symbol, requires, lessons):
    return {"id": cid, "track": track, "title": title, "subtitle": subtitle, "symbol": symbol,
            "requires": list(requires), "lessons": lessons}


# ---------------------------------------------------------------- mirrors of the Swift checks

def _pts(path):
    f = path["pts"]
    pts = [(f[i], f[i + 1]) for i in range(0, len(f), 2)]
    if path.get("closed") and len(pts) > 2:
        pts = pts + [pts[0]]
    return pts


def ink_strokes(frame):
    return [_pts(p) for p in frame["paths"] if p.get("role", "ink") == "ink"]


def dist_to_lines(p, lines):
    best = float("inf")
    for ln in lines:
        if len(ln) == 1:
            best = min(best, dist(p, ln[0]))
            continue
        for i in range(1, len(ln)):
            d = seg_dist(p, ln[i - 1], ln[i])
            if d < best:
                best = d
    return best


def trace_score(guide_lines, strokes, tol):
    spacing = tol / 3
    gl = [g for g in guide_lines if len(g) > 1]
    drawn = [s for s in strokes if s]
    if not gl or not drawn:
        return 0.0, 0.0
    ratio = sum(length(x) for x in drawn) / max(1e-6, sum(length(x) for x in gl))
    if ratio > MAX_INK_RATIO:
        return 0.0, 0.0
    cov = tot = 0
    for g in gl:
        for p in resample(g, spacing):
            tot += 1
            if dist_to_lines(p, drawn) <= tol:
                cov += 1
    on = n = 0
    for s in drawn:
        for p in (s if len(s) == 1 else resample(s, spacing)):
            n += 1
            if dist_to_lines(p, gl) <= tol * ACCURACY_SLACK:
                on += 1
    return cov / max(1, tot), on / max(1, n)


def centroid(strokes):
    xs = ys = 0.0
    n = 0
    for s in strokes:
        for p in resample(s, 0.01):
            xs += p[0]
            ys += p[1]
            n += 1
    return (xs / n, ys / n) if n else None


def gaps(frame_strokes):
    cs = [centroid(f) for f in frame_strokes]
    return [dist(cs[i - 1], cs[i]) for i in range(1, len(cs))]


def spacing_matches(g, kind):
    n = len(g)
    if n < 2:
        return False

    def mean(s):
        return sum(s) / len(s) if s else 0.0
    if kind == "even":
        m = mean(g)
        return m > 1e-6 and all(0.45 * m <= x <= 1.7 * m for x in g)
    if kind == "easeIn":
        return mean(g[(n + 1) // 2:]) >= 1.25 * mean(g[:n // 2]) and g[-1] > g[0]
    if kind == "easeOut":
        return mean(g[:n // 2]) >= 1.25 * mean(g[(n + 1) // 2:]) and g[0] > g[-1]
    if kind == "easeInOut":
        return n >= 3 and mean(g[1:-1]) >= 1.25 * max(g[0], g[-1])
    return False


def chamfer(a, b):
    sa = [p for s in a for p in resample(s, 0.02)]
    sb = [p for s in b for p in resample(s, 0.02)]
    ab = sum(dist_to_lines(p, b) for p in sa) / len(sa)
    ba = sum(dist_to_lines(p, a) for p in sb) / len(sb)
    return (ab + ba) / 2


def bend(s):
    if len(s) < 3:
        return 0.0
    c = dist(s[0], s[-1])
    if c < 1e-6:
        return float("inf")
    return max(seg_dist(p, s[0], s[-1]) for p in s) / c


def end_gap(strokes):
    ends = []
    for i, s in enumerate(strokes):
        if length(s) >= 0.02:
            ends.append(s[0])
            ends.append(s[-1])
    if not ends:
        return float("inf")
    worst = 0.0
    for k, e in enumerate(ends):
        best = min(dist(e, o) for j, o in enumerate(ends) if j != k)
        worst = max(worst, best)
    return worst


def wobble(s):
    step = 0.01
    pts = resample(s, step)
    r = 4
    if len(pts) <= 2 * r + 2:
        return 0.0
    tot = 0.0
    n = 0
    for i in range(r, len(pts) - r):
        sx = sum(pts[k][0] for k in range(i - r, i + r + 1)) / (2 * r + 1)
        sy = sum(pts[k][1] for k in range(i - r, i + r + 1)) / (2 * r + 1)
        tot += dist(pts[i], (sx, sy))
        n += 1
    return tot / n / step


def check_step(where, s):
    """Raises if a drawing step would not pass with its own guide, or would pass with a scribble."""
    if s["kind"] not in ("trace", "frames", "animate"):
        return
    frames_ = s["guide"]["frames"]
    per = [ink_strokes(f) for f in frames_]
    if s["kind"] == "trace":
        per = per[:1]
    allstrokes = [st for f in per for st in f]
    shapes = [st for st in allstrokes if length(st) >= 0.05]
    for c in s["checks"]:
        t = c["type"]
        if t == "trace":
            for i, f in enumerate(per):
                cov, acc = trace_score(f, f, c["tolerance"])
                assert cov >= c["coverage"] and acc >= c["accuracy"], (where, "self trace", i, cov, acc)
        elif t == "straight":
            b = max(bend(st) for st in shapes)
            assert b <= c["value"], (where, "straight", b)
        elif t == "closed":
            g = end_gap(shapes)
            assert g <= c["value"], (where, "closed", g)
        elif t == "smooth":
            w = max(wobble(st) for st in shapes)
            assert w <= c["value"], (where, "smooth", w)
        elif t == "spacing":
            g = gaps(per)
            assert spacing_matches(g, c["spacing"]), (where, "spacing", c["spacing"], [round(x, 4) for x in g])
        elif t == "loop":
            steps = [chamfer(per[i - 1], per[i]) for i in range(1, len(per))]
            wrap = chamfer(per[-1], per[0])
            med = sorted(steps)[len(steps) // 2]
            assert wrap <= c["value"] * med + 0.015, (where, "loop", wrap, med)
    # Scribbles must fail the trace check: one all over the page always fails, and most quick scribbles
    # (1.5 times the guide's length) inside the area around the guide fail too.
    tc = s["checks"][0]
    rng = random.Random(7)
    for i, f in enumerate(per):
        big = [[(rng.uniform(0.05, ASPECT - 0.05), rng.uniform(0.05, 0.95)) for _ in range(40)]]
        cov, acc = trace_score(f, big, tc["tolerance"])
        assert not (cov >= tc["coverage"] and acc >= tc["accuracy"]), (where, "page scribble passes", i, cov, acc)
        xs = [p[0] for st in f for p in st]
        ys = [p[1] for st in f for p in st]
        x0, x1, y0, y1 = min(xs) - 0.15, max(xs) + 0.15, min(ys) - 0.15, max(ys) + 0.15
        want = 1.5 * sum(length(st) for st in f)
        passed = 0
        for _ in range(6):
            near = [(rng.uniform(x0, x1), rng.uniform(y0, y1))]
            while length(near) < want:
                near.append((rng.uniform(x0, x1), rng.uniform(y0, y1)))
            cov, acc = trace_score(f, [near], tc["tolerance"])
            if cov >= tc["coverage"] and acc >= tc["accuracy"]:
                passed += 1
        assert passed <= 1, (where, "near scribbles pass", i, passed)


def check_lesson(lesson_):
    n = len(lesson_["steps"])
    assert 3 <= n <= 8, (lesson_["id"], "steps", n)
    for s in lesson_["steps"]:
        check_step(lesson_["id"] + "/" + s["id"], s)
        if s["kind"] == "frames":
            assert 2 <= len(s["guide"]["frames"]) <= 12, (lesson_["id"], s["id"], "frame count")
        if s["kind"] == "animate":
            assert 2 <= len(s["guide"]["frames"]) <= 24, (lesson_["id"], s["id"], "frame count")
        if s["kind"] == "watch":
            nf = len(s["guide"]["frames"])
            assert 1 <= len(s["beats"]) <= 10 and not s.get("checks"), (lesson_["id"], s["id"], "beats")
            for b in s["beats"]:
                assert b["say"].strip(), (lesson_["id"], s["id"], "empty beat")
                assert 0 <= b["from"] <= b["to"] < nf, (lesson_["id"], s["id"], "beat range", b)
                for o in b.get("show", []):
                    assert o in ("onion", "trail", "chart", "slow"), (lesson_["id"], s["id"], o)
                    if o in ("trail", "chart"):
                        assert b["to"] > b["from"], (lesson_["id"], s["id"], "trail needs frames", b)
        elif "beats" in s:
            raise AssertionError((lesson_["id"], s["id"], "only watch steps have beats"))
        if s["kind"] == "quiz":
            q = s["quiz"]
            assert 2 <= len(q["choices"]) <= 4 and 0 <= q["answer"] < len(q["choices"]), (lesson_["id"], s["id"])
            assert len(set(q["choices"])) == len(q["choices"]), (lesson_["id"], s["id"], "dup choice")
