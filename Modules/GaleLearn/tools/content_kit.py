"""Reusable drawings for the lessons: balls, beans, faces, mouths, figures, scenery."""
import math

from learn_geo import (ASPECT, GROUND, TAU, arc, catmull, circle, dist, ease_in_out, ellipse, lerp, lerp2, line,
                       partial, polygon, rect, rotate, squash_ellipse, star, walk_pose)
from learn_dsl import F, G, accent, helper, ink

CX = ASPECT / 2
BALL_R = 0.07


def ground(y=GROUND, x0=0.04, x1=ASPECT - 0.04):
    return helper(line((x0, y), (x1, y)), w=0.006)


def ball(cx, cy, r=BALL_R, stretch=1.0, angle=math.pi / 2, w=None):
    """A ball, squashed (stretch < 1) or stretched (stretch > 1) along `angle` (pi/2 = up-down)."""
    if abs(stretch - 1) < 1e-6:
        return ink(circle(cx, cy, r, n=32), w=w, closed=True)
    return ink(squash_ellipse(cx, cy, r, stretch, angle, n=32), w=w, closed=True)


def ghost_ball(cx, cy, r=BALL_R, stretch=1.0, angle=math.pi / 2):
    pts = circle(cx, cy, r, n=24) if abs(stretch - 1) < 1e-6 else squash_ellipse(cx, cy, r, stretch, angle, n=24)
    return helper(pts, closed=True)


def draw_on(paths_pts, steps=10, hold_end=10, extras=(), role="ink", w=None):
    """Frames where lines get drawn one after another (for 'watch how it's drawn' guides)."""
    total = sum(max(1e-6, _len(p)) for p in paths_pts)
    frames_ = []
    for i in range(steps + 1):
        t = ease_in_out(i / steps) * total
        paths = list(extras)
        run = 0.0
        for p in paths_pts:
            L = max(1e-6, _len(p))
            if t <= run:
                break
            share = min(1.0, (t - run) / L)
            pts = partial(p, share)
            paths.append(ink(pts, w=w) if role == "ink" else accent(pts))
            run += L
        if len(paths) == len(extras):
            paths.append(ink(partial(paths_pts[0], 0.01), w=w))
        frames_.append(F(paths, hold=hold_end if i == steps else 1))
    return frames_


def _len(p):
    return sum(dist(p[i - 1], p[i]) for i in range(1, len(p)))


def dot(x, y, r=0.016):
    return accent(circle(x, y, r, n=14), closed=True)


# ---------------------------------------------------------------- bean character

def bean(cx, base_y, h=0.36, w=0.2, squash=1.0, lean=0.0, eyes=True, line_w=None):
    """A bean-shaped buddy standing on base_y. squash < 1 is squashed (wider), > 1 stretched."""
    hh = h * squash
    ww = w / math.sqrt(squash)
    r = ww / 2
    top = base_y - hh
    # A rounded box (superellipse) keeps a bean look whether it's squashed or stretched.
    a, b = ww / 2, hh / 2
    cy = base_y - b
    pts = []
    for i in range(48):
        t = TAU * i / 48 - math.pi / 2
        c, s_ = math.cos(t), math.sin(t)
        pts.append((cx + a * math.copysign(abs(c) ** (2 / 2.8), c), cy + b * math.copysign(abs(s_) ** (2 / 2.8), s_)))
    pts = rotate(pts, lean, (cx, base_y))
    paths = [ink(pts, w=line_w, closed=True)]
    if eyes:
        ey = top + min(r, hh / 2) * 0.9
        for side in (-1, 1):
            e = (cx + side * ww * 0.18 + r * 0.25, ey)
            e = rotate([e], lean, (cx, base_y))[0]
            paths.append(ink(circle(e[0], e[1], 0.014 * min(1.4, max(0.7, 1 / squash)), n=10), closed=True))
    return paths


# ---------------------------------------------------------------- faces and mouths

MOUTHS = ("A", "E", "O", "U", "MBP", "FV", "L", "rest")
MOUTH_WORDS = {"A": "A (open)", "E": "E (wide)", "O": "O (round)", "U": "U (small)", "MBP": "M B P",
               "FV": "F V", "L": "L (tongue)", "rest": "Rest"}


def mouth(shape, cx, cy, s=1.0):
    """Mouth drawings for lip sync. s scales the mouth (1 = big, for mouth-only lessons)."""
    def E(rx, ry, oy=0.0):
        return ellipse(cx, cy + oy * s, rx * s, ry * s, n=36)
    paths = []
    if shape == "A":
        paths.append(ink(E(0.17, 0.13), closed=True))
        paths.append(ink(arc(cx, cy + 0.13 * s, 0.1 * s, 0.06 * s, math.pi * 1.1, math.pi * 1.9, n=14)))
        paths.append(ink(line((cx - 0.12 * s, cy - 0.085 * s), (cx + 0.12 * s, cy - 0.085 * s))))
    elif shape == "E":
        paths.append(ink(E(0.22, 0.07), closed=True))
        paths.append(ink(line((cx - 0.17 * s, cy - 0.01 * s), (cx + 0.17 * s, cy - 0.01 * s))))
    elif shape == "O":
        paths.append(ink(E(0.1, 0.13), closed=True))
        paths.append(ink(E(0.055, 0.08), closed=True))
    elif shape == "U":
        paths.append(ink(E(0.065, 0.07), closed=True))
        paths.append(ink(E(0.03, 0.035), closed=True))
    elif shape == "MBP":
        top = catmull([(cx - 0.17 * s, cy + 0.005 * s), (cx - 0.07 * s, cy - 0.03 * s), (cx, cy - 0.02 * s),
                       (cx + 0.07 * s, cy - 0.03 * s), (cx + 0.17 * s, cy + 0.005 * s)], per=6)
        bottom = catmull([(cx - 0.17 * s, cy + 0.005 * s), (cx, cy + 0.06 * s), (cx + 0.17 * s, cy + 0.005 * s)], per=8)
        paths.append(ink(top))
        paths.append(ink(bottom))
        paths.append(ink(line((cx - 0.15 * s, cy + 0.008 * s), (cx + 0.15 * s, cy + 0.008 * s))))
    elif shape == "FV":
        paths.append(ink(E(0.16, 0.06, 0.01), closed=True))
        paths.append(ink(rect(cx - 0.09 * s, cy - 0.045 * s, cx + 0.09 * s, cy + 0.015 * s), closed=True))
    elif shape == "L":
        paths.append(ink(E(0.15, 0.11), closed=True))
        paths.append(ink(arc(cx, cy - 0.04 * s, 0.07 * s, 0.07 * s, 0.05 * math.pi, 0.95 * math.pi, n=14)))
    else:  # rest
        paths.append(ink(catmull([(cx - 0.16 * s, cy - 0.01 * s), (cx, cy + 0.03 * s), (cx + 0.16 * s, cy - 0.01 * s)],
                                 per=10)))
    return paths


def face(cx=CX, cy=0.47, r=0.36, mouth_shape="rest", eyes_open=1.0):
    paths = [ink(circle(cx, cy, r, n=48), closed=True)]
    for side in (-1, 1):
        paths += eye(cx + side * r * 0.38, cy - r * 0.18, r * 0.2, eyes_open)
    paths += mouth(mouth_shape, cx, cy + r * 0.45, s=r * 1.15)
    return paths


def eye(cx, cy, size, openness=1.0, pupil=True):
    """An almond eye. openness 1 = open, 0 = closed (a curved line)."""
    lower = arc(cx, cy, size, size * 0.55, 0, math.pi, n=16)
    if openness <= 0.02:
        return [ink(arc(cx, cy + size * 0.05, size, size * 0.35, 0, math.pi, n=16))]
    upper = arc(cx, cy + size * 0.55 * (1 - openness), size, size * 0.55 * openness + 1e-3, math.pi, 2 * math.pi, n=16)
    out = [ink(upper + lower[1:-1] + [upper[0]], closed=False)]
    if pupil and openness > 0.6:
        out.append(ink(circle(cx, cy + size * 0.05, size * 0.28, n=14), closed=True))
    return out


# ---------------------------------------------------------------- figures

def figure(pose, parts=("far_leg", "far_arm", "torso", "near_leg", "near_arm", "head"), roles=None):
    roles = roles or {}
    paths = []
    for name in parts:
        role = roles.get(name, "ink")
        pts = pose[name]
        closed = name == "head"
        if role == "ink":
            paths.append(ink(pts, closed=closed))
        elif role == "accent":
            paths.append(accent(pts, closed=closed))
        else:
            paths.append(helper(pts, closed=closed))
    return paths


def stick_pose(cx, ground_y, size, spine, head_r, arms, legs):
    """A free stick pose. spine: list of points from hips to neck. arms/legs: lists of point lists."""
    paths = [ink(spine)]
    neck = spine[-1]
    d = (spine[-1][0] - spine[-2][0], spine[-1][1] - spine[-2][1])
    L = math.hypot(*d) or 1
    hc = (neck[0] + d[0] / L * head_r, neck[1] + d[1] / L * head_r)
    paths.append(ink(circle(hc[0], hc[1], head_r, n=24), closed=True))
    for a in arms + legs:
        paths.append(ink(a))
    return paths


# ---------------------------------------------------------------- scenery

def tree(x, base_y, h=0.32, w=0.16):
    trunk_w = w * 0.18
    crown_c = (x, base_y - h * 0.68)
    crown = []
    bumps = 7
    for i in range(bumps * 8):
        a = TAU * i / (bumps * 8) - math.pi / 2
        r = w * 0.5 * (1 + 0.1 * math.cos(bumps * a))
        crown.append((crown_c[0] + r * math.cos(a), crown_c[1] + r * 0.85 * math.sin(a)))
    trunk_top = crown_c[1] + w * 0.38
    return [ink(crown, closed=True),
            ink([(x - trunk_w, trunk_top), (x - trunk_w, base_y)]),
            ink([(x + trunk_w, trunk_top), (x + trunk_w, base_y)])]


def heart(cx, cy, size):
    pts = []
    for i in range(48):
        t = TAU * i / 48
        x = 16 * math.sin(t) ** 3
        y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        pts.append((cx + x * size / 17, cy - y * size / 17))
    return pts


def cloud_puff(cx, cy, r, bumps=6, phase=0.0):
    return [(cx + r * (1 + 0.12 * math.cos(bumps * a + phase)) * math.cos(a),
             cy + r * (1 + 0.12 * math.cos(bumps * a + phase)) * math.sin(a))
            for a in (TAU * i / 60 - math.pi / 2 for i in range(60))]


def mountains(x0, x1, base, height, phase=0.0, period=0.5, n=80):
    """A periodic mountain ridge (tileable: shifting by `period` gives the same shape)."""
    pts = []
    for i in range(n):
        x = lerp(x0, x1, i / (n - 1))
        u = (x + phase) / period
        y = base - height * (0.55 + 0.3 * math.sin(TAU * u) + 0.15 * math.sin(TAU * 2 * u + 1.3))
        pts.append((x, y))
    return pts
