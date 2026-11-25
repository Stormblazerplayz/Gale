"""Track "2D Animation": Animate Like a Pro.

Real animation, taught the way studios teach it: watch a narrated demo (with onion skin, motion trails and
timing charts), then animate it yourself in Gale's real editor over a locked guide layer.
Every drawing is computed here: gravity, pendulums, springs, a walk from leg angles, lip sync from sounds.
"""
import math

from learn_geo import (ASPECT, GROUND, TAU, arc, catmull, circle, ease_in_out, ellipse, lerp, line)
from learn_dsl import (F, G, accent, animate, beat, chk_loop, chk_spacing, course, helper, ink, lesson, quiz, read,
                       tool, watch)
from content_kit import BALL_R, CX, ball, bean, eye, figure, ghost_ball, ground, mouth
from courses_motion import ponytail_sim
from courses_principles import ink_squash
from learn_geo import walk_pose

TRACK = "animation"
FLOOR = GROUND
BC = FLOOR - BALL_R


# ---------------------------------------------------------------- helpers

def slide(x0, x1, n, curve):
    """n positions from x0 to x1 following an easing curve (0..1 -> 0..1)."""
    return [lerp(x0, x1, curve(k / (n - 1))) for k in range(n)]


def even(t):
    return t


def pendulum(px, py, length_, theta0, n):
    """A pendulum's swing from one side to the other, timed by real pendulum physics (cosine in time)."""
    out = []
    for k in range(n):
        a = theta0 * math.cos(math.pi * k / (n - 1))
        out.append((px + length_ * math.sin(a), py + length_ * math.cos(a)))
    return out


def brows(cx, cy, r, mood):
    """Eyebrows for a face: mood is 'calm', 'happy', 'surprised', 'sad' or 'angry'."""
    out = []
    for side in (-1, 1):
        ex = cx + side * r * 0.38
        ey = cy - r * 0.18
        lift = {"calm": 0.0, "happy": 0.03, "surprised": 0.1, "sad": 0.02, "angry": -0.02}[mood] * r / 0.36
        y = ey - r * 0.36 - lift
        inner = cx + side * r * 0.16
        outer = cx + side * r * 0.6
        if mood == "sad":
            a, b = (inner, y - r * 0.08), (outer, y + r * 0.05)
        elif mood == "angry":
            a, b = (inner, y + r * 0.08), (outer, y - r * 0.06)
        else:
            a, b = (inner, y), (outer, y)
        mid = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2 - r * (0.05 if mood in ("happy", "surprised", "calm") else 0.02))
        out.append(ink(catmull([a, mid, b], per=6)))
    return out


def smile(cx, cy, w, curve):
    """A mouth line: curve > 0 smiles, < 0 frowns."""
    return ink(catmull([(cx - w, cy - curve * 0.5), (cx, cy + curve), (cx + w, cy - curve * 0.5)], per=8))


def expression(mood, cx=CX, cy=0.5, r=0.34):
    """The parts of a face that change with feeling: brows, eyes and mouth (the head outline is the background)."""
    paths = brows(cx, cy, r, mood)
    eye_open = {"calm": 0.85, "happy": 0.55, "surprised": 1.0, "sad": 0.6, "angry": 0.65}[mood]
    for side in (-1, 1):
        paths += eye(cx + side * r * 0.38, cy - r * 0.18, r * 0.2, eye_open)
    my = cy + r * 0.48
    if mood == "happy":
        paths.append(smile(cx, my, r * 0.42, r * 0.16))
    elif mood == "surprised":
        paths.append(ink(ellipse(cx, my + r * 0.04, r * 0.12, r * 0.16, n=28), closed=True))
    elif mood == "sad":
        paths.append(smile(cx, my + r * 0.06, r * 0.3, -r * 0.1))
    elif mood == "angry":
        paths.append(ink([(cx - r * 0.28, my + r * 0.04), (cx, my), (cx + r * 0.28, my + r * 0.04)]))
    else:
        paths.append(smile(cx, my, r * 0.3, r * 0.04))
    return paths


def head_outline(cx=CX, cy=0.5, r=0.34):
    return [helper(circle(cx, cy, r, n=48), w=0.008, closed=True)]


def travel_bounce(x0, x1, top, n_fall=5, n_rise=4, r=BALL_R * 1.3, keep=0.7):
    """One whole bounce that travels across the screen: the drop, the squash on impact, the recoil back up.
    Worked out with gravity (height goes with time squared) and even sideways speed.
    The ball stretches along the way it's moving, more when it's faster. Returns (paths per frame, track)."""
    bc = FLOOR - r
    h = bc - top
    n = n_fall + 1 + n_rise
    xs = [lerp(x0, x1, k / (n - 1)) for k in range(n)]
    ys = []
    for k in range(n_fall):
        u = k / n_fall
        ys.append(top + h * u * u)
    ys.append(FLOOR - r * 0.66)  # contact (squashed, still touching the floor)
    top2 = bc - keep * h
    for k in range(1, n_rise + 1):
        u = k / n_rise
        ys.append(bc - (bc - top2) * (1 - (1 - u) ** 2))
    frames_, track = [], []
    for k in range(n):
        if k == n_fall:
            frames_.append([ink_squash(xs[k], FLOOR, r, 0.66)])
            track.append((xs[k], ys[k]))
            continue
        # Speed from the neighbours: fast frames stretch along the path, slow ones stay round.
        a = (xs[max(0, k - 1)], ys[max(0, k - 1)] if k - 1 != n_fall else bc)
        b = (xs[min(n - 1, k + 1)], ys[min(n - 1, k + 1)] if k + 1 != n_fall else bc)
        dx, dy = b[0] - a[0], b[1] - a[1]
        # Stretch goes with the falling or rising speed (the sideways drift is slow and steady).
        speed = abs(dy) / 2
        vmax = 0.3 * h
        stretch = 1 + 0.4 * min(1.0, speed / vmax) ** 2
        if k == 0 or k == n - 1:
            stretch = 1.0  # hanging at the top: round
        frames_.append([ball(xs[k], ys[k], r, stretch=stretch, angle=math.atan2(dy, dx))])
        track.append((xs[k], ys[k]))
    return frames_, track


# ---------------------------------------------------------------- the course

def pro():
    L = []

    # 1. Timing & spacing ------------------------------------------------------
    n = 9
    y_even, y_ease = 0.36, 0.7
    xs_even = slide(0.18, ASPECT - 0.18, n, even)
    xs_ease = slide(0.18, ASPECT - 0.18, n, ease_in_out)
    both = [F([ball(xs_even[k], y_even), ball(xs_ease[k], y_ease)],
              notes=[("Even", 0.12, y_even - 0.12), ("Slow in & out", 0.2, y_ease - 0.12)] if k == 0 else None)
            for k in range(n)]
    ease_only = [F([ball(x, 0.55)]) for x in xs_ease]
    lanes = [helper(line((0.1, y_even + 0.09), (ASPECT - 0.1, y_even + 0.09)), w=0.004),
             helper(line((0.1, y_ease + 0.09), (ASPECT - 0.1, y_ease + 0.09)), w=0.004)]
    n7 = 7
    xs7 = slide(0.2, ASPECT - 0.2, n7, ease_in_out)
    L.append(lesson("pro.timing", "Timing & Spacing", "The secret behind every animation that feels good.", [
        watch("Same frames, different feel",
              "Both balls take 9 frames to cross. Only the spacing is different.",
              G(both, fps=8, bg=lanes),
              [beat("Okay, two balls. They both take exactly nine frames to get across. Just watch them for a "
                    "second.", 0, n - 1),
               beat("How many frames something takes is called timing. So these two have the same timing.", 0, n - 1,
                    ["onion"]),
               beat("How far it moves between frames is called spacing. The top ball moves the same gap every time, "
                    "so it slides along like a robot.", 0, n - 1, ["onion", "slow"]),
               beat("Now the bottom one. Tiny gaps at the start, big gaps in the middle, tiny gaps again at the end. "
                    "That's slow in and slow out.", 0, n - 1, ["onion", "slow"]),
               beat("Watch them both at full speed again. See how the bottom one feels heavier, more real? Pros ease "
                    "almost everything.", 0, n - 1)]),
        watch("Read a timing chart",
              "Animators plan spacing with a timing chart: one tick per drawing.",
              G(ease_only, fps=8, track=[(x, 0.55) for x in xs_ease]),
              [beat("Here's just the eased ball. Each dot is where it sits on one frame.", 0, n - 1, ["trail"]),
               beat("Down at the bottom is a timing chart. One tick for every drawing. Ticks close together mean "
                    "slow, ticks far apart mean fast.", 0, n - 1, ["chart", "trail"]),
               beat("See how the ticks bunch up at both ends? That's exactly the slow in and slow out you just "
                    "watched.", 0, n - 1, ["chart", "onion", "slow"]),
               beat("Before you animate anything, you can sketch a chart like this. It's your plan for the "
                    "spacing.", 0, n - 1, ["chart"])]),
        animate("Animate a slow in and slow out",
                "Your project opens in Gale with 7 frames and a faint guide. On every frame, draw the ball over the "
                "guide. Small gaps at the ends, big gaps in the middle.",
                [F([ball(x, 0.55)]) for x in xs7], fps=8,
                bg=[helper(line((0.1, 0.64), (ASPECT - 0.1, 0.64)), w=0.004)],
                checks=[chk_spacing("easeInOut")],
                hint="Turn on onion skin to see the last frame while you draw the next one.",
                tips=["Start on the left. Draw a nice round ball sitting on the line.",
                      "Only a tiny move. It's just getting going.",
                      "A bigger gap now. It's picking up speed.",
                      "The middle. This is the biggest gap, it's at full speed.",
                      "Still a big gap, but it's starting to slow down.",
                      "Smaller again. It's easing in to stop.",
                      "Just a tiny move to the end. Nice and gentle."]),
        quiz("A ball moves the same distance every frame. It will look...",
             ["Mechanical, like a robot", "Heavy and natural", "Like it's bouncing"], 0,
             "Even spacing has no speeding up or slowing down, so it feels stiff."),
        quiz("On a timing chart, ticks close together mean the thing is moving...", ["Slowly", "Fast"], 0,
             "Close drawings mean small moves each frame: slow."),
    ]))

    # 2. The bouncing ball: one complete lesson ----------------------------------
    fr, tr = travel_bounce(0.26, ASPECT - 0.26, 0.14)
    contact = 5
    last = len(fr) - 1
    bounce = [F(p, hold=(3 if k == 0 else (2 if k == contact else (3 if k == last else 1))),
                notes=[({0: "Top", contact: "Squash!", last: "Top again"}[k], tr[k][0], 0.06)]
                if k in (0, contact, last) else None)
              for k, p in enumerate(fr)]
    L.append(lesson("pro.bounce", "The Bouncing Ball",
                    "The whole bounce in one lesson: the drop, the squash, and the recoil back up.", [
        watch("Watch a whole bounce",
              "A real bounce, worked out with gravity: it drops, squashes on the floor, and springs back up.",
              G(bounce, fps=12, bg=[ground()], track=tr),
              [beat("Here's a full bounce, from the top, down to the floor, and back up again. Watch it a few "
                    "times first.", 0, last),
               beat("It starts at the top, nice and round. Up here it's barely moving, so this is the slowest "
                    "moment.", 0, 0),
               beat("Then gravity takes over. See how each gap is bigger than the one before? It's speeding up all "
                    "the way down.", 0, contact - 1, ["trail", "onion", "slow"]),
               beat("Because it's going so fast, it stretches along the way it's moving. Long and thin, like a "
                    "jellybean.", contact - 2, contact - 1, ["onion", "slow"]),
               beat("Splat. On the frame it touches the floor, it squashes flat and wide. Same amount of ball, just "
                    "a different shape.", contact, contact),
               beat("Now the recoil. It springs right back up, stretched again, because it's moving fast.", contact,
                    contact + 1, ["onion", "slow"]),
               beat("And as it rises, it slows down. Big gaps first, then smaller and smaller, until it hangs at the "
                    "top.", contact, last, ["trail", "chart"]),
               beat("Notice it only gets back to about two thirds of the height. Every bounce loses a little "
                    "energy.", 0, last, ["onion"])]),
        watch("Squash and stretch, up close",
              "Slow motion around the impact: stretch, squash, stretch.",
              G(bounce, fps=12, bg=[ground()], track=tr),
              [beat("Let's slow right down around the hit. Three drawings do almost all the work here.", contact - 1,
                    contact + 1, ["slow"]),
               beat("Just before: stretched long, pointing along the path.", contact - 1, contact - 1),
               beat("Contact: squashed flat. It gets wider as it gets shorter, so it never looks like it's "
                    "shrinking.", contact, contact),
               beat("Just after: stretched again as it pops back up. Stretch, squash, stretch. That's the whole "
                    "trick.", contact + 1, contact + 1),
               beat("Look at the path too. Even steps sideways, gravity up and down, so it makes two smooth "
                    "arcs.", 0, last, ["trail"])]),
        animate("Animate the whole bounce",
                "Ten frames: the drop, the squash, and the recoil. On every frame, draw the ball over the faint guide.",
                [F(p) for p in fr], fps=12, bg=[ground()], loop=False, tolerance=0.04, accuracy=0.75,
                checks=[chk_spacing("easeInOut")],
                hint="Small gaps at the top, big gaps near the floor, a flat squash on frame 6, then small gaps again "
                     "as it rises.",
                tips=["The top. Draw it perfectly round, it's barely moving up here.",
                      "Just a tiny drop. Keep it really close to frame 1.",
                      "A bigger gap now. It's starting to speed up.",
                      "An even bigger gap. Stretch it a little, long and thin.",
                      "The biggest gap. Stretch it the most, it's about to hit.",
                      "Splat! Squash it flat and wide, right on the floor.",
                      "The recoil. It shoots back up fast, so stretch it tall again.",
                      "Still rising, but the gap's smaller. A bit less stretch.",
                      "Almost at the top. A small gap, nearly round.",
                      "The top again. Round, and a bit lower than where it started."]),
        quiz("Where is a bouncing ball stretched the most?", ["Just before and just after it hits the floor",
                                                              "At the very top", "While it's squashed"], 0,
             "It's moving fastest around the hit, so that's where it stretches."),
        quiz("When the ball squashes on the floor, it should...", ["Get wider as it gets shorter",
                                                                   "Shrink all over"], 0,
             "Keep the same amount of ball: shorter means wider."),
        quiz("After the bounce, the ball goes back up...", ["Lower than where it started", "Higher than before",
                                                            "Exactly as high"], 0,
             "Each bounce loses some energy, so it never quite gets back to the start."),
    ]))

    # 3. Anticipation & overshoot -----------------------------------------------
    plan = [(1.0, 0.0, 6, "Stand"), (0.85, 0.0, 2, None), (0.66, 0.0, 6, "Anticipation"), (1.38, 0.05, 1, "Launch")]
    jump, jtrack = [], []
    for sq_, lift, hold, note in plan:
        jump.append(F(bean(CX, FLOOR - lift, squash=sq_), hold=hold, notes=[(note, CX, 0.08)] if note else None))
        jtrack.append((CX, FLOOR - lift - 0.36 * sq_ / 2))
    g, v, y = 0.013, -0.09, -0.05
    while True:
        v += g
        y += v
        if y >= 0:
            break
        jump.append(F(bean(CX, FLOOR + y, squash=1.0 + max(-0.12, min(0.28, -v * 2.6)))))
        jtrack.append((CX, FLOOR + y - 0.18))
    land = [(0.6, 1, "Land"), (0.78, 1, None), (1.12, 2, "Overshoot"), (0.95, 2, None), (1.0, 8, "Settle")]
    for sq_, hold, note in land:
        jump.append(F(bean(CX, FLOOR, squash=sq_), hold=hold, notes=[(note, CX, 0.08)] if note else None))
        jtrack.append((CX, FLOOR - 0.36 * sq_ / 2))
    i_ant = 2
    i_launch = 3
    i_land = len(jump) - 5
    BH, BW = 0.44, 0.25
    keys = [bean(CX, FLOOR - lift, h=BH, w=BW, squash=sq_)
            for lift, sq_ in ((0.0, 1.0), (0.0, 0.66), (0.05, 1.38), (0.2, 1.05), (0.0, 0.72), (0.0, 1.12),
                              (0.0, 1.0))]
    L.append(lesson("pro.anticipation", "Anticipation & Overshoot", "Wind up before, wobble after.", [
        watch("A jump, pro style",
              "Watch what happens before and after the jump.",
              G(jump, fps=12, bg=[ground()], track=jtrack),
              [beat("Meet the bean. It's about to jump. Watch the whole thing once.", 0, len(jump) - 1),
               beat("Before it jumps, it squashes down. That's anticipation. It's a little warning that something's "
                    "about to happen.", 0, i_ant, ["slow"]),
               beat("Then it launches, stretched tall. Going from squash straight to stretch is what makes the jump "
                    "feel strong.", i_ant, i_launch, ["onion"]),
               beat("In the air it just follows gravity. Up fast, slow at the top, down fast.", i_launch, i_land - 1,
                    ["trail", "onion"]),
               beat("When it lands, it squashes, pops up a little too tall, then settles. Nothing in real life stops "
                    "dead.", i_land, len(jump) - 1, ["slow"]),
               beat("So, anticipation before, overshoot after. Put those on almost any action and it comes "
                    "alive.", 0, len(jump) - 1)]),
        animate("Animate the key poses",
                "Seven key poses: stand, crouch, launch, in the air, land, overshoot, settle. Draw the bean on every "
                "frame over the guide.",
                [F(p, hold=h) for p, h in zip(keys, (6, 6, 2, 4, 2, 2, 8))], fps=12,
                bg=[ground()], loop=False, tolerance=0.04, accuracy=0.75,
                hint="The crouch is short and wide. The launch is tall and thin. Keep the bean the same size overall.",
                tips=["Standing. Just the normal bean, relaxed.",
                      "The crouch. Short and wide, like it's loading a spring.",
                      "Launch! Tall and thin, stretching up off the ground.",
                      "In the air. Nearly its normal shape, just a little stretched.",
                      "Landing. Squash it short and wide again.",
                      "The overshoot. A little too tall, like it's bouncing back.",
                      "Settled. Back to the normal bean, calm and still."]),
        quiz("Anticipation is...", ["A small move the opposite way before the main action",
                                    "Stopping completely after an action", "Making things move faster"], 0,
             "Crouch before a jump, pull back before a throw."),
        quiz("Why add an overshoot when landing?", ["So it doesn't stop dead and look stiff",
                                                    "To make it land faster"], 0,
             "Weight keeps going a little, then settles back."),
    ]))

    # 4. Arcs -------------------------------------------------------------------
    pivot = (CX, 0.1)
    plen = 0.58
    swing = pendulum(pivot[0], pivot[1], plen, math.radians(48), 9)
    rope = [F([helper(line(pivot, p), w=0.006), ball(p[0], p[1], r=0.06)]) for p in swing]
    straight = [lerp(swing[0][0], swing[-1][0], ease_in_out(k / 8)) for k in range(9)]
    wrong = [F([ball(x, swing[0][1], r=0.06)]) for x in straight]
    arc_bg = [helper(arc(pivot[0], pivot[1], plen, plen, math.pi / 2 - math.radians(50),
                         math.pi / 2 + math.radians(50), n=40), w=0.004)]
    ping = rope + list(reversed(rope[1:-1]))
    ptrack = swing + list(reversed(swing[1:-1]))
    L.append(lesson("pro.arcs", "Arcs", "Living things move along curves, not straight lines.", [
        watch("Swing on an arc",
              "A pendulum, timed by real physics.",
              G(ping, fps=12, bg=[helper([pivot, pivot], w=0.02)], track=ptrack),
              [beat("This is a pendulum. The rope keeps the ball the same distance from the top, so it swings on a "
                    "curve called an arc.", 0, len(ping) - 1),
               beat("Here's its path. Almost everything alive moves on arcs like this. Arms, heads, tails, "
                    "jumps.", 0, 8, ["trail"]),
               beat("It's slow at each end and quick at the bottom. Gravity gives you slow in and slow out for "
                    "free.", 0, 8, ["chart", "onion", "slow"])]),
        watch("Straight looks wrong",
              "The same timing, moving in a straight line.",
              G(wrong, fps=12, track=[(x, swing[0][1]) for x in straight]),
              [beat("Now here's the same spacing in a straight line. It looks like a machine, doesn't it? Not a "
                    "swing at all.", 0, 8, ["trail"]),
               beat("So whenever something looks stiff, check the arcs. Turn on onion skin and look at the "
                    "path.", 0, 8, ["onion"])]),
        animate("Animate the swing",
                "Draw the ball on every frame along the arc. Slow at the ends, fast at the bottom.",
                [F([ball(p[0], p[1], r=0.06)]) for p in swing], fps=12, bg=arc_bg, loop=False,
                checks=[chk_spacing("easeInOut")],
                hint="Follow the faint curve. Check the path with onion skin.",
                tips=["The far left of the swing. It's stopped here for a moment.",
                      "Just a tiny move down the curve.",
                      "A bit bigger. It's speeding up.",
                      "Bigger again, heading for the bottom.",
                      "The very bottom of the arc. The biggest gap, it's fastest here.",
                      "Coming up the other side. Still a big gap.",
                      "Slowing down now. A smaller gap.",
                      "Nearly there. Just a little move.",
                      "The far right. It stops here before swinging back."]),
        quiz("A character's hand waves hello. Its path should be...", ["A curve", "A straight line", "A zigzag"], 0,
             "Joints turn, so the hand moves on an arc."),
    ]))

    # 5. Overlapping action -----------------------------------------------------
    nn = 24
    hxs = []
    for k in range(nn):
        hxs.append(0.3 + 0.62 * ease_in_out(min(1.0, k / 8)))
    hy, hr = 0.38, 0.11
    tails = ponytail_sim(hxs, hy, hr)
    over = [F([ink(circle(x, hy, hr, n=36), closed=True), ink(catmull(t, per=3))]) for x, t in zip(hxs, tails)]
    otrack = [t[-1] for t in tails]
    stop = 8
    peak = max(range(stop, nn), key=lambda k: tails[k][-1][0] - hxs[k])
    picks = [0, 4, stop, peak, (peak + nn) // 2, nn - 1]
    L.append(lesson("pro.overlap", "Overlapping Action", "Loose parts drag, then catch up.", [
        watch("The tail drags behind",
              "A head moves and stops. The ponytail is worked out like a swinging spring.",
              G(over, fps=12, track=otrack),
              [beat("A head slides over and stops. Keep your eye on the ponytail.", 0, nn - 1),
               beat("While the head moves, the hair drags behind. The root is stuck to the head, but the tip is "
                    "loose.", 0, stop, ["onion", "slow"]),
               beat("When the head stops, the hair doesn't. It swings past, swings back, then settles.", stop,
                    nn - 1, ["trail"]),
               beat("Watch the tip. It moves the most and stops the latest. The root stops first.", stop, nn - 1,
                    ["onion", "slow"]),
               beat("Different parts stopping at different times. That's overlapping action, and it's what makes "
                    "things feel real.", 0, nn - 1)]),
        animate("Animate the drag and settle",
                "Six key frames: start, moving, stop, swing past, swing back, rest. Draw the head and ponytail on "
                "every frame.",
                [F([ink(circle(hxs[k], hy, hr, n=36), closed=True), ink(catmull(tails[k], per=3))], hold=h)
                 for k, h in zip(picks, (4, 3, 2, 3, 3, 8))], fps=12, loop=False,
                hint="The tip of the ponytail moves the most and stops last.",
                tips=["The start. The head is still and the ponytail hangs straight down.",
                      "Moving. The head slides right and the ponytail trails out behind it.",
                      "The head stops. The hair is still dragging behind, it hasn't caught up.",
                      "Swing past. Now the hair flies forward, past the head.",
                      "Swing back. It comes back the other way, but not as far.",
                      "Rest. The ponytail hangs straight down again."]),
        quiz("A dog runs and stops. Its ears...", ["Flop forward, then settle", "Stop at the exact same time"], 0,
             "Loose parts carry on, then catch up."),
    ]))

    # 6. Walk cycle -------------------------------------------------------------
    POSES = ["Passing", "Up", "Contact", "Down", "Passing", "Up", "Contact", "Down"]
    walk8 = [F(figure(walk_pose(k / 8)), notes=[(POSES[k], CX, 0.08)]) for k in range(8)]
    head8 = [walk_pose(k / 8)["head_center"] for k in range(8)]
    walk12 = [F(figure(walk_pose(k / 12), roles={"near_leg": "accent", "near_arm": "accent"})) for k in range(12)]
    head12 = [walk_pose(k / 12)["head_center"] for k in range(12)]
    L.append(lesson("pro.walk", "Walk Cycle", "The four poses that make every walk.", [
        watch("The four poses",
              "One step has four key poses. The leg angles are worked out like a real gait.",
              G(walk8, fps=6, bg=[ground()], track=head8),
              [beat("This is a walk cycle. Two steps that loop around forever.", 0, 7),
               beat("Contact. The front heel just touches down, and the legs are spread wide.", 2, 2),
               beat("Down. The front knee bends to catch the weight. This is the lowest the body gets.", 3, 3),
               beat("Passing. One leg swings past the other one.", 4, 4),
               beat("Up. The back foot pushes off and the body rises to its highest point.", 5, 5),
               beat("Now watch the head. It bobs down and up twice per cycle, once for every step.", 0, 7,
                    ["trail", "onion"]),
               beat("And the arms swing the opposite way to the legs. Right leg forward, left arm forward.", 0, 7,
                    ["slow"])]),
        watch("Full speed",
              "Twelve frames at twelve frames per second: about one second per cycle.",
              G(walk12, fps=12, bg=[ground()], track=head12),
              [beat("At full speed it's twelve drawings a second. The highlighted arm and leg are the ones nearest "
                    "to us.", 0, 11),
               beat("The last frame leads straight back into the first, so it loops with no jump.", 0, 11,
                    ["onion"])]),
        animate("Animate a walk cycle",
                "Eight frames, two steps. Draw the figure on every frame: body and head first, then legs, then arms.",
                [F(figure(walk_pose(k / 8))) for k in range(8)], fps=8, bg=[ground()],
                checks=[chk_loop()],
                hint="Use onion skin. Each frame only changes a little from the one before.",
                tips=["Passing. The legs are close together, one swinging past the other.",
                      "Up. The back foot pushes off and the body rises.",
                      "Contact. The front heel touches down, legs wide apart.",
                      "Down. The front knee bends and the body dips.",
                      "Passing again, with the other leg in front now.",
                      "Up. Push off, rise up.",
                      "Contact. Heel down, legs wide.",
                      "Down. Catch the weight, then it loops back to frame 1."]),
        quiz("When is the body lowest in a walk?", ["The down pose, just after contact", "The passing pose",
                                                    "The up pose"], 0,
             "The knee bends to catch the weight, so the body dips."),
        quiz("When the right leg swings forward, the right arm swings...", ["Back", "Forward too"], 0,
             "Arms swing opposite to the legs for balance."),
    ]))

    # 7. Lip sync ---------------------------------------------------------------
    FX, FY, FR = CX, 0.48, 0.36
    face_bg = [helper(circle(FX, FY, FR, n=48), w=0.008, closed=True)]
    for side in (-1, 1):
        face_bg += [helper([(p["pts"][i], p["pts"][i + 1]) for i in range(0, len(p["pts"]), 2)], w=0.006)
                    for p in eye(FX + side * FR * 0.38, FY - FR * 0.18, FR * 0.2, 1.0)]
    MYc, MS = FY + FR * 0.45, FR * 1.15
    chart = [("rest", "Rest"), ("A", "A, as in cat"), ("E", "E, as in see"), ("O", "O, as in go"),
             ("U", "U, as in you"), ("MBP", "M, B and P"), ("FV", "F and V"), ("L", "L")]
    chart_frames = [F(mouth(m, FX, MYc, MS), hold=10, notes=[(w, FX, 0.04)]) for m, w in chart]
    words = [("rest", 6, "..."), ("A", 4, "Hi"), ("E", 3, ""), ("rest", 3, ""), ("MBP", 2, "Mom"), ("O", 4, ""),
             ("MBP", 3, ""), ("rest", 8, "")]
    sync = [F(mouth(m, FX, MYc, MS), hold=h, notes=[(t, FX, 0.04)] if t else None) for m, h, t in words]
    L.append(lesson("pro.lipsync", "Lip Sync", "Make a character talk.", [
        watch("The mouth chart",
              "Eight mouths cover nearly every sound. Say each one out loud as you watch.",
              G(chart_frames, fps=12, bg=face_bg),
              [beat("Good news: you don't need a new mouth for every letter. About eight shapes cover nearly "
                    "everything.", 0, 7),
               beat("Rest. The mouth just closed and relaxed, for the gaps between words.", 0, 0),
               beat("A, like in cat. The jaw drops and the mouth opens wide. Try saying ah.", 1, 1),
               beat("E, like in see. Wide and flat, almost a smile, with the teeth showing.", 2, 2),
               beat("O, like in go. Round and open. And U, like in you, is a smaller, tighter circle.", 3, 4),
               beat("M, B and P all press the lips together. Say mom slowly and feel your lips shut.", 5, 5),
               beat("F and V tuck the top teeth onto the bottom lip. And L lifts the tongue up behind the "
                    "teeth.", 6, 7),
               beat("Try saying each one yourself in a mirror. It's how real animators do it.", 0, 7, ["slow"])]),
        watch("Say \"Hi Mom\"",
              "Listen for the main sounds, then pick a mouth for each.",
              G(sync, fps=12, bg=face_bg, loop=False),
              [beat("Let's make this face say, hi mom.", 0, len(sync) - 1),
               beat("Say it slowly yourself. Hi is really two sounds. Ah, then ee.", 1, 2),
               beat("So that's the A mouth, wide open, then the E mouth, wide and flat.", 1, 2, ["onion"]),
               beat("Mom starts with M, so the lips press shut. Then a round O. Then shut again for the last M.", 4,
                    6, ["slow"]),
               beat("Notice the vowels get held longer than the quick sounds. You only animate what you can "
                    "hear.", 0, len(sync) - 1),
               beat("Pro tip. Put each mouth a frame or two before its sound. It looks more in sync that "
                    "way.", 0, len(sync) - 1)]),
        animate("Animate \"Hi Mom\"",
                "Draw the mouth on every frame over the guide: rest, A, E, rest, M, O, M, rest. Gale already set "
                "the holds, so press play to see it talk.",
                [F(mouth(m, FX, MYc, MS), hold=h) for m, h, _ in words], fps=12, bg=face_bg, loop=False,
                hint="M, B and P are lips pressed together. O is round.",
                tips=["Rest. A soft, closed mouth before they talk.",
                      "Ah, the first half of hi. Open the mouth wide.",
                      "Ee, the end of hi. Wide and flat, with the teeth showing.",
                      "A quick rest between the two words.",
                      "M. Press the lips together, the line where they meet in the middle.",
                      "O. A round, open mouth for the middle of mom.",
                      "M again. Lips shut for the last sound.",
                      "Rest. Back to the relaxed mouth. Press play and watch it talk."]),
        quiz("Which mouth shape do the M sounds in \"Mom\" use?", ["Lips pressed together", "Wide open", "Round O"],
             0, "M, B and P all start with the lips shut."),
        quiz("Should the mouth change for every single letter?", ["No, just the sounds you hear",
                                                                 "Yes, one shape per letter"], 0,
             "Too many shapes looks fluttery."),
    ]))

    # 8. Face & expression ------------------------------------------------------
    EX, EY, ER = CX, 0.5, 0.34
    hb = head_outline(EX, EY, ER)
    moods = [("calm", 8), ("happy", 10), ("surprised", 10), ("sad", 10), ("angry", 10)]
    mood_words = {"calm": "Calm", "happy": "Happy", "surprised": "Surprised", "sad": "Sad", "angry": "Angry"}
    faces = [F(expression(m, EX, EY, ER), hold=h, notes=[(mood_words[m], EX, 0.08)]) for m, h in moods]
    take = [("happy", 8), ("calm", 1), ("surprised", 10), ("sad", 12)]
    L.append(lesson("pro.expression", "Face & Expression", "Brows, eyes and mouth tell the feeling.", [
        watch("Read a face",
              "Five feelings on the same face. Only the brows, eyes and mouth change.",
              G(faces, fps=12, bg=hb),
              [beat("Same face, five feelings. And only three things change. The brows, the eyes and the "
                    "mouth.", 0, 4),
               beat("Happy. The mouth curves up, and the eyes squint a little, pushed up by the cheeks.", 1, 1),
               beat("Surprised. The brows shoot up, the eyes open wide, and the mouth drops open.", 2, 2),
               beat("Sad. The inner ends of the brows lift up, and the mouth curves down.", 3, 3),
               beat("Angry. The inner ends of the brows push down toward the nose.", 4, 4),
               beat("Here's a fun test. Cover the mouth with your hand. You can still tell the feeling from the "
                    "brows.", 0, 4, ["slow"])]),
        animate("Animate a change of feeling",
                "Happy, then something surprises them, then they feel sad. Draw the brows, eyes and mouth on every "
                "frame.",
                [F(expression(m, EX, EY, ER), hold=h) for m, h in take], fps=12, bg=hb, loop=False,
                hint="Start with the brows. They show the feeling fastest.",
                tips=["Happy. Brows relaxed and slightly up, squinty eyes, a big curved smile.",
                      "Just one frame of calm. It breaks the happy face before the surprise.",
                      "Surprised! Brows way up, eyes wide open, mouth a round O.",
                      "Sad. Lift the inner ends of the brows and turn the mouth down."]),
        quiz("Which part of the face shows feelings the most?", ["The eyebrows", "The ears", "The nose"], 0,
             "Brows move a lot and are easy to read."),
        quiz("In a sad face, the inner ends of the brows go...", ["Up", "Down"], 0,
             "Inner ends down is angry; inner ends up is sad."),
    ]))

    return course("pro", TRACK, "Animate Like a Pro",
                  "Real animation with voice lessons: timing, the bouncing ball, arcs, walks and acting",
                  "film.stack", [], L)
