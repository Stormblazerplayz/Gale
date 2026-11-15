"""Track "2D Animation": The 12 Principles of Animation."""
import math

from learn_geo import (ASPECT, GROUND, TAU, Camera, arc, box_edges, catmull, circle, dist, ease_in_out, ease_out,
                       ellipse, lerp, lerp2, limb, line, move, rect, rot_y, spring_follow)
from learn_dsl import (F, G, accent, chk_smooth, chk_spacing, chk_straight, course, frames, helper, ink, lesson, quiz,
                       read, still, trace)
from content_kit import BALL_R, CX, ball, bean, dot, ghost_ball, ground, stick_pose

TRACK = "animation"
FLOOR = GROUND
BALL_FLOOR = FLOOR - BALL_R


def vertical_bounce(x, n=12, top=0.2, squash=True, r=BALL_R, floor=FLOOR):
    """One bounce in place, computed from gravity: y follows a parabola in time.
    Frame 0 is the contact. Stretch grows with speed; the contact frame squashes."""
    out = []
    h = floor - r - top
    for k in range(n):
        u = k / n
        s = 2 * u - 1
        y = floor - r - h * (1 - s * s)
        speed = abs(s)
        if not squash:
            out.append(ball(x, y, r))
        elif k == 0:
            out.append(ink_squash(x, floor, r, 0.72))
        else:
            out.append(ball(x, y, r, stretch=1 + 0.3 * speed ** 2, angle=math.pi / 2))
    return out


def ink_squash(x, floor, r, k):
    """A ball squashed on the floor (k < 1 = flatter), still touching the floor."""
    ry = r * k
    return ball(x, floor - ry, r, stretch=1 / k, angle=0.0)


def principles():
    L = []

    # 1. Squash & stretch
    sq = [F([p]) for p in vertical_bounce(CX)]
    pair = []
    stiff = vertical_bounce(0.4, squash=False)
    soft = vertical_bounce(0.93, squash=True)
    for a, b in zip(stiff, soft):
        pair.append(F([a, b], notes=[("Stiff", 0.4, 0.1), ("Squishy", 0.93, 0.1)]))
    r = BALL_R * 1.3
    L.append(lesson("principles.squash", "Squash & Stretch", "Soft things squash and stretch as they move.", [
        read("Squish!",
             "When a soft ball hits the ground, it squashes flat. When it moves fast, it stretches long. This makes "
             "things feel soft and alive. The trick: the ball never gets bigger or smaller overall. If it gets "
             "wider, it gets shorter.", G(sq, bg=[ground()])),
        read("Stiff or squishy?",
             "Both balls bounce with the same timing. The left one stays perfectly round, so it feels hard, like "
             "a marble. The right one squashes and stretches, so it feels soft and bouncy.", G(pair, bg=[ground()])),
        frames("Three squashy drawings",
               "Draw the ball falling (stretched tall), hitting the ground (squashed flat), then bouncing up (round).",
               [F([ball(CX, 0.45, r, stretch=1.35)]), F([ink_squash(CX, FLOOR, r, 0.65)]), F([ball(CX, 0.5, r)])],
               bg=[ground()], hint="Stretched means tall and thin. Squashed means short and wide.", fps=4),
        quiz("When the ball squashes flat, it should also...", ["Get wider", "Get smaller all over", "Disappear"], 0,
             "It keeps the same amount of ball: flatter means wider."),
    ]))

    # 2. Anticipation
    jump = []
    plan = [(1.0, 0.0, 4), (0.9, 0.0, 1), (0.75, 0.0, 1), (0.62, 0.0, 4), (1.35, 0.0, 1)]
    for sq_, lift, hold in plan:
        jump.append(F(bean(CX, FLOOR - lift, squash=sq_), hold=hold))
    g = 0.012
    v = -0.085
    y = 0.0
    while True:
        v += g
        y += v
        if y >= 0:
            break
        jump.append(F(bean(CX, FLOOR + y, squash=1.0 + max(-0.1, min(0.25, -v * 2.5)))))
    jump.append(F(bean(CX, FLOOR, squash=0.7), hold=2))
    jump.append(F(bean(CX, FLOOR, squash=1.0), hold=8))
    for k in (1, 2, 3):
        jump[k]["notes"] = [{"text": "crouch...", "x": round(CX + 0.25, 3), "y": 0.5}]
    big_small = []
    for k in range(16):
        t = k / 16
        small = 1 - 0.12 * max(0.0, math.sin(TAU * t)) if t < 0.5 else 1.0
        big = 1 - 0.38 * max(0.0, math.sin(TAU * t)) if t < 0.5 else 1.0
        hs = 0.06 * max(0.0, -math.sin(TAU * t))
        hb = 0.3 * max(0.0, -math.sin(TAU * t))
        big_small.append(F(bean(0.4, FLOOR - hs, squash=small) + bean(0.95, FLOOR - hb, squash=big),
                           notes=[("little hop", 0.4, 0.1), ("big jump", 0.95, 0.1)]))
    L.append(lesson("principles.anticipation", "Anticipation", "Get ready before the big move.", [
        read("Get ready...",
             "Before a big move, there's a small move the other way. Before you jump, you crouch down. Before you "
             "throw, you pull your arm back. This is anticipation: it tells the audience something is about to happen.",
             G(jump, bg=[ground()])),
        read("Big move, big wind-up",
             "The bigger the action, the bigger the anticipation. A little hop needs only a little crouch. A huge "
             "jump needs a deep crouch.", G(big_small, bg=[ground()])),
        frames("Crouch, then jump",
               "Draw the bean standing, crouching down low, stretching up as it takes off, then up in the air.",
               [F(bean(CX, FLOOR, squash=1.0, eyes=False)), F(bean(CX, FLOOR, squash=0.62, eyes=False)),
                F(bean(CX, FLOOR - 0.05, squash=1.35, eyes=False)), F(bean(CX, FLOOR - 0.3, squash=1.05, eyes=False))],
               bg=[ground()], hint="The crouch is short and wide, the take-off is tall and thin.", fps=4),
        quiz("A character is about to punch. What's the anticipation?",
             ["Pulling the fist back first", "The fist hitting", "Walking away afterwards"], 0,
             "Pulling back first warns the audience that a punch is coming."),
    ]))

    # 3. Staging
    def wave_pose(cx, base, s, arms_out=True):
        hip = (cx, base - 0.4 * s)
        neck = (cx, base - 0.78 * s)
        legs = [[hip, (cx - 0.12 * s, base)], [hip, (cx + 0.12 * s, base)]]
        sh = lerp2(hip, neck, 0.9)
        if arms_out:
            arms = [[sh, (cx - 0.25 * s, base - 0.62 * s), (cx - 0.4 * s, base - 0.55 * s)],
                    [sh, (cx + 0.24 * s, base - 0.86 * s), (cx + 0.3 * s, base - 1.08 * s)]]
        else:
            arms = [[sh, (cx + 0.06 * s, base - 0.55 * s), (cx - 0.04 * s, base - 0.62 * s)],
                    [sh, (cx - 0.05 * s, base - 0.58 * s), (cx + 0.05 * s, base - 0.66 * s)]]
        return stick_pose(cx, base, s, [hip, neck], 0.09 * s, arms, legs)
    clutter = []
    for i in range(9):
        x = 0.12 + 0.13 * i
        clutter.append(helper(rect(x, 0.2 + 0.05 * (i % 3), x + 0.09, 0.62 + 0.04 * (i % 2)), closed=True))
    stage = [F(clutter + wave_pose(1.12, 0.8, 0.28, arms_out=False), hold=16, notes=[("Hard to read", CX, 0.1)]),
             F(wave_pose(CX, 0.88, 0.7), hold=16, notes=[("Clear!", CX, 0.1)])]
    sil = still(wave_pose(0.4, 0.86, 0.6, arms_out=False) + wave_pose(0.98, 0.86, 0.6, arms_out=True),
                notes=[("arms hidden", 0.4, 0.95), ("arms clear", 0.98, 0.95)])
    L.append(lesson("principles.staging", "Staging", "Show the idea so clearly nobody can miss it.", [
        read("Make it clear",
             "Staging means showing your idea so clearly that nobody can miss it. Put the important thing where "
             "the eye goes, keep the background simple, and give it room.", G(stage)),
        read("The silhouette test",
             "Imagine your character filled in solid black. Can you still tell what it's doing? On the left the "
             "arms are hidden in front of the body. On the right they stick out, so the pose reads instantly.", sil),
        trace("A clear pose", "Trace a waving pose with the arms well clear of the body.", wave_pose(CX, 0.92, 0.78),
              hint="Head and body first, then the legs, then the arms."),
        quiz("How can you check if a pose is clear?",
             ["Fill it in black and see if you can still tell what's happening", "Add more details", "Make it smaller"], 0,
             "If the silhouette reads, the pose reads."),
    ]))

    # 4. Straight ahead & pose to pose
    pivot = (CX, 0.12)
    rod = 0.58
    theta0 = math.radians(40)

    def pend(theta, bob_role=ink):
        tip = (pivot[0] + rod * math.sin(theta), pivot[1] + rod * math.cos(theta))
        return [ink(line(pivot, tip, n=3)), bob_role(circle(tip[0], tip[1], 0.065, n=28), closed=True)]
    angles = [theta0 * math.cos(math.pi * k / 4) for k in range(5)]
    keys = [F(pend(angles[0]), hold=10, notes=[("Key 1", 0.3, 0.9)]),
            F(pend(angles[0]) + pend(angles[4]), hold=10, notes=[("Key 2", 1.05, 0.9)]),
            F(pend(angles[0]) + pend(angles[4]) + pend(angles[2]), hold=10, notes=[("Breakdown", CX, 0.9)]),
            F(sum((pend(a) for a in angles), []), hold=12, notes=[("Inbetweens", CX, 0.92)])]
    for a in angles[1:] + list(reversed(angles[:-1])):
        keys.append(F(pend(a)))
    L.append(lesson("principles.posetopose", "Straight Ahead & Pose to Pose", "Two ways to plan an animation.", [
        read("Two ways to animate",
             "Straight ahead: draw frame 1, then 2, then 3, in order, making it up as you go. It's great for wild "
             "things like fire and water. Pose to pose: draw the important key poses first, then fill in the frames "
             "between them, called inbetweens. It's great for planned acting.",
             G([F(pend(a)) for a in angles + list(reversed(angles[1:-1]))], fps=8)),
        read("Keys first, then inbetweens",
             "Here's pose to pose: first the two keys (the ends of the swing), then a breakdown in the middle, then "
             "the inbetweens. Notice the inbetweens bunch up near the ends, where the swing slows down.", G(keys, fps=8)),
        frames("Swing the pendulum",
               "Draw one swing from left to right. Put drawings close together at the ends and further apart in the middle.",
               [F(pend(a)) for a in angles], hint="The pendulum is slowest at the ends of its swing and fastest at the bottom.",
               checks=[chk_spacing("easeInOut")], fps=6, loop=False),
        quiz("Which way works best for a wild, flickering fire?", ["Straight ahead", "Pose to pose"], 0,
             "Fire changes shape all the time, so drawing it frame after frame keeps it lively."),
    ]))

    # 5. Follow through & overlapping action
    n = 26
    xs = []
    for k in range(n):
        t = min(1.0, k / 9)
        xs.append(0.3 + 0.55 * ease_out(t))
    tip_x = spring_follow([x for x in xs], stiffness=0.28, damping=0.62)
    head_y = 0.6
    hr = 0.12

    def critter(x, tx):
        base = (x, head_y - hr)
        lean = max(-0.25, min(0.25, (tx - x) * 3))
        tip = (base[0] + 0.28 * math.sin(lean), base[1] - 0.28 * math.cos(lean))
        mid = (base[0] + 0.14 * math.sin(lean * 0.4), base[1] - 0.14 * math.cos(lean * 0.4))
        stalk = catmull([base, mid, tip], per=6)
        return [ink(circle(x, head_y, hr, n=36), closed=True), ink(stalk), ink(circle(tip[0], tip[1] - 0.03, 0.03, n=14), closed=True)]
    follow = [F(critter(x, tx)) for x, tx in zip(xs, tip_x)]
    follow[-1]["hold"] = 10
    # pick: biggest overshoot after stopping, swing back, settled
    after = list(range(9, n))
    over = max(after, key=lambda k: tip_x[k] - xs[k])
    back = min(range(over, n), key=lambda k: tip_x[k] - xs[k])
    picks = [over, back, n - 1]
    wave_arm = []
    for k in range(16):
        t = k / 16
        sh = (CX - 0.15, 0.55)
        a1 = math.radians(150) + math.radians(30) * math.sin(TAU * t)
        a2 = a1 + math.radians(25) * math.sin(TAU * t - 0.9)
        a3 = a2 + math.radians(25) * math.sin(TAU * t - 1.8)
        pts = limb(sh, [-a1, -a2, -a3], [0.22, 0.2, 0.08])
        wave_arm.append(F([ink(pts), dot(*pts[0])], notes=[("shoulder leads, hand follows", CX, 0.9)]))
    L.append(lesson("principles.follow", "Follow Through", "Loose parts keep moving after the body stops.", [
        read("Keep going, then settle",
             "When a character stops, not everything stops at once. Hair, ears, a tail or an antenna keep going, "
             "then swing back and settle. This is follow through.", G(follow, bg=[ground(0.73)])),
        read("Overlapping action",
             "Different parts move at different times. When you wave, your shoulder moves first, then your elbow, "
             "then your hand, each a little later. That delay makes motion feel loose and real.", G(wave_arm)),
        frames("The antenna catches up",
               "The critter just stopped. Draw the antenna leaning forward, swinging back, then standing still.",
               [F(critter(xs[k], tip_x[k])) for k in picks], bg=[ground(0.73)],
               hint="First the antenna overshoots forward, then it swings back a little, then it settles.", fps=4),
        quiz("A dog runs and stops suddenly. What do its floppy ears do?",
             ["Keep moving forward, then swing back and settle", "Stop at exactly the same time", "Point straight up"], 0,
             "Loose parts carry on moving, then settle: that's follow through."),
    ]))

    # 6. Slow in & slow out
    def car(x, y=0.62):
        body = [(x - 0.17, y), (x - 0.17, y - 0.08), (x - 0.08, y - 0.08), (x - 0.04, y - 0.15), (x + 0.08, y - 0.15),
                (x + 0.12, y - 0.08), (x + 0.17, y - 0.08), (x + 0.17, y)]
        return [ink(body + [body[0]]), ink(circle(x - 0.09, y + 0.02, 0.04, n=18), closed=True),
                ink(circle(x + 0.09, y + 0.02, 0.04, n=18), closed=True)]
    cx_ = [0.25 + 0.83 * ease_in_out(k / 8) for k in range(9)]
    ticks = [helper(line((x, 0.74), (x, 0.8))) for x in cx_] + [helper(line((0.25, 0.77), (1.08, 0.77)))]
    car_frames = [F(car(x)) for x in cx_]
    car_frames[-1]["hold"] = 6
    car_frames[0]["hold"] = 6
    rows = []
    kinds = [("even", lambda t: t), ("speed up", lambda t: t * t), ("slow down", ease_out)]
    chart_bg = []
    for i, (name, f) in enumerate(kinds):
        y = 0.25 + 0.25 * i
        chart_bg.append(helper(line((0.25, y), (1.1, y))))
        for k in range(7):
            x = 0.25 + 0.85 * f(k / 6)
            chart_bg.append(helper(line((x, y - 0.03), (x, y + 0.03))))
    for k in range(7):
        paths = []
        notes = []
        for i, (name, f) in enumerate(kinds):
            y = 0.25 + 0.25 * i
            paths.append(ball(0.25 + 0.85 * f(k / 6), y - 0.07, r=0.035))
            notes.append((name, 0.12, y))
        rows.append(F(paths, hold=2, notes=notes))
    slow_x = [0.25 + 0.8 * ease_out(k / 4) for k in range(5)]
    L.append(lesson("principles.slowinout", "Slow In & Slow Out", "Speed up gently, slow down gently.", [
        read("Gentle starts and stops",
             "Things rarely start or stop instantly. A car starts slowly, speeds up, then slows down before it "
             "stops. To show this, put drawings close together near the start and end (slow) and further apart "
             "in the middle (fast). The ticks underneath show where each drawing goes.", G(car_frames, fps=8, bg=ticks)),
        read("Spacing charts",
             "Animators plan spacing with a little chart. Each tick is one frame. Ticks close together mean slow; "
             "ticks far apart mean fast. Watch the three balls: same start, same end, different spacing.",
             G(rows, fps=8, bg=chart_bg)),
        frames("Slow to a stop",
               "The ball rolls in fast and slows down to a stop. Make each gap smaller than the one before.",
               [F([ball(x, 0.6)]) for x in slow_x], bg=[ground(0.67)],
               hint="Big gap, smaller gap, smaller still, tiny gap.", checks=[chk_spacing("easeOut")], fps=6, loop=False),
        quiz("The gaps between drawings get smaller and smaller. The thing is...",
             ["Speeding up", "Slowing down", "Moving at the same speed"], 1,
             "Smaller gaps mean it moves less each frame, so it's slowing down."),
    ]))

    # 7. Arcs
    arm_frames = []
    trail = []
    for k in range(12):
        t = k / 12
        a = math.radians(-35) + math.radians(70) * (0.5 - 0.5 * math.cos(TAU * t))
        sh = (CX, 0.2)
        e = math.radians(10)
        pts = limb(sh, [a, a + e], [0.3, 0.28])
        trail.append(pts[-1])
        arm_frames.append(F([ink(pts), dot(*sh)] + ([accent(list(trail))] if len(trail) > 1 else [])))
    g = 0.02
    throw = []
    path = []
    vx, vy = 0.09, -0.16
    x, y = 0.15, 0.8
    for k in range(12):
        path.append((x, y))
        throw.append(F([ball(x, y, r=0.05)] + ([accent(list(path))] if len(path) > 1 else [])))
        x += vx
        vy += g
        y += vy
    throw[-1]["hold"] = 8
    parab = [(lerp(0.2, ASPECT - 0.2, u), 0.82 - 0.62 * (1 - (2 * u - 1) ** 2)) for u in (i / 40 for i in range(41))]
    along = [0.0, 0.25, 0.5, 0.75, 1.0]
    L.append(lesson("principles.arcs", "Arcs", "Natural motion follows curved paths.", [
        read("Curves, not lines",
             "Living things move along curves, not straight lines. A swinging arm, a turning head, a thrown ball: "
             "they all follow arcs. Motion in straight lines looks stiff and robotic. The orange line is the path "
             "of the hand.", G(arm_frames, fps=10)),
        read("A thrown ball",
             "Gravity bends a thrown ball's path into a smooth arc: up, over and down.", G(throw, fps=10)),
        trace("Trace the arc", "Trace the path of a thrown ball in one smooth move.", [ink(parab)],
              hint="Keep it smooth over the top. No flat spots or corners.", checks=[chk_smooth()]),
        frames("Along the arc", "Draw the ball at each point along the arc.",
               [F([ball(lerp(0.2, ASPECT - 0.2, u), 0.82 - 0.62 * (1 - (2 * u - 1) ** 2), r=0.05)]) for u in along],
               bg=[accent(parab)], hint="Follow the orange arc with each ball.", fps=6, loop=False),
        quiz("Why animate along arcs?", ["They make motion look natural", "They're quicker to draw", "Computers like them"], 0,
             "Joints swing and gravity pulls, so real motion curves."),
    ]))

    # 8. Secondary action
    walk_frames = []
    bag_len = 0.16
    for k in range(16):
        t = k / 16
        x = 0.25 + 0.05 * k
        bob = 0.02 * abs(math.sin(TAU * t))
        body = bean(x, FLOOR - bob, h=0.4, squash=1 + 0.05 * math.sin(TAU * 2 * t))
        swing = math.radians(25) * math.sin(TAU * t * 2 - 1.2)
        hand = (x + 0.06, FLOOR - bob - 0.2)
        bag = (hand[0] + bag_len * math.sin(swing), hand[1] + bag_len * math.cos(swing))
        bagbox = [(bag[0] - 0.05, bag[1]), (bag[0] + 0.05, bag[1]), (bag[0] + 0.05, bag[1] + 0.08), (bag[0] - 0.05, bag[1] + 0.08)]
        walk_frames.append(F(body + [ink(line(hand, bag)), ink(bagbox, closed=True)]))
    bx = CX
    still_body = bean(bx, FLOOR, h=0.62, w=0.32)
    hand = (bx + 0.1, FLOOR - 0.32)
    sw = math.radians(20)
    bag = (hand[0] + 0.2 * math.sin(sw), hand[1] + 0.2 * math.cos(sw))
    bagbox = [(bag[0] - 0.07, bag[1]), (bag[0] + 0.07, bag[1]), (bag[0] + 0.07, bag[1] + 0.11), (bag[0] - 0.07, bag[1] + 0.11)]
    L.append(lesson("principles.secondary", "Secondary Action", "Small extra moves that add personality.", [
        read("A little extra",
             "A secondary action is a small extra movement that supports the main one. A character walks (the main "
             "action) while their bag swings, or they whistle, or they wipe their brow. It adds personality, but it "
             "should never steal the show.", G(walk_frames, bg=[ground()])),
        trace("Bean with a bag", "Trace the bean and its swinging bag.",
              still_body + [ink(line(hand, bag)), ink(bagbox, closed=True)], bg=[ground()],
              hint="Draw the bean first, then the strap, then the bag."),
        quiz("Which is a secondary action for someone walking?", ["Their scarf flapping", "Their legs stepping", "The ground"], 0,
             "The legs are the main action. The flapping scarf adds to it."),
        quiz("A secondary action should...",
             ["Support the main action without stealing attention", "Be bigger than the main action",
              "Only happen when nothing else moves"], 0,
             "It's a supporting actor, not the star."),
    ]))

    # 9. Timing
    tim = []
    for k in range(12):
        fast_x = 0.2 + 0.93 * min(1.0, k / 3)
        slow_x = 0.2 + 0.93 * k / 11
        tim.append(F([ball(fast_x, 0.32, r=0.05), ball(slow_x, 0.7, r=0.05)],
                      notes=[("4 frames", 0.2, 0.18), ("12 frames", 0.2, 0.86)]))
    tim[-1]["hold"] = 6
    L.append(lesson("principles.timing", "Timing", "More frames is slower, fewer is faster.", [
        read("Frames are time",
             "Timing is how many frames an action takes. More frames make it slower. Fewer frames make it faster. "
             "Both balls travel the same distance, but the top one does it in 4 frames and the bottom one in 12.",
             G(tim, fps=12)),
        read("Timing shows weight",
             "Timing also shows how heavy something is. Heavy things take longer to get going and longer to stop. "
             "Light things zip around. At 12 frames per second, 12 frames is one second.",
             G(tim, fps=12)),
        frames("Make it quick", "Zip the ball across the page in just 3 frames, with even gaps.",
               [F([ball(x, 0.5)]) for x in (0.25, 0.67, 1.09)], hint="Big, even jumps make it fast.",
               checks=[chk_spacing("even")], fps=6, loop=False),
        quiz("At 12 frames per second, how long is 24 frames?", ["1 second", "2 seconds", "12 seconds"], 1,
             "24 frames divided by 12 frames each second is 2 seconds."),
    ]))

    # 10. Exaggeration
    exf = []
    for k in range(16):
        t = k / 16
        s = math.sin(TAU * t)
        n_up = 0.1 * max(0.0, s)
        e_up = 0.32 * max(0.0, s)
        n_sq = 1 - 0.1 * max(0.0, -s)
        e_sq = 1 - 0.38 * max(0.0, -s)
        n_st = 1 + 0.08 * max(0.0, s)
        e_st = 1 + 0.35 * max(0.0, s)
        exf.append(F(bean(0.4, FLOOR - n_up, squash=n_sq * n_st) + bean(0.95, FLOOR - e_up, squash=e_sq * e_st),
                     notes=[("real", 0.4, 0.1), ("exaggerated", 0.95, 0.1)]))
    fc = (CX, 0.5)
    shock = [ink(circle(fc[0], fc[1], 0.34, n=48), closed=True),
             ink(circle(fc[0] - 0.13, fc[1] - 0.1, 0.08, n=24), closed=True),
             ink(circle(fc[0] + 0.13, fc[1] - 0.1, 0.08, n=24), closed=True),
             ink(ellipse(fc[0], fc[1] + 0.16, 0.09, 0.11, n=28), closed=True),
             ink(arc(fc[0] - 0.14, fc[1] - 0.26, 0.08, 0.04, math.pi * 1.1, math.pi * 1.9, n=10)),
             ink(arc(fc[0] + 0.14, fc[1] - 0.26, 0.08, 0.04, math.pi * 1.1, math.pi * 1.9, n=10))]
    L.append(lesson("principles.exaggeration", "Exaggeration", "Push it further to make it fun.", [
        read("Push it!",
             "Real life can look dull when it's animated. Exaggeration pushes things further: a bigger squash, a "
             "higher jump, a wider smile. Push it until it's fun, but keep it believable.", G(exf, bg=[ground()])),
        trace("Totally shocked", "Trace this exaggerated surprised face: huge eyes, raised brows, round open mouth.", shock,
              hint="Big circle first, then the eyes, then the mouth and brows."),
        quiz("What does exaggeration do?", ["Makes actions clearer and more fun", "Makes the file smaller",
                                            "Makes the drawing look like a photo"], 0,
             "Pushing a pose makes the feeling easier to read."),
    ]))

    # 11. Solid drawing
    cam = Camera(center=(0.95, 0.52), scale=0.22, dist=5.0, pitch=math.radians(22))
    solid = []
    for k in range(12):
        vis, hid = box_edges(cam, size=(1.3, 1.3, 1.3), rot=(0.0, math.radians(90 * k / 12), 0.0))
        solid.append(F([ink(rect(0.15, 0.37, 0.45, 0.67), closed=True)] + [ink(e) for e in vis],
                       notes=[("flat", 0.3, 0.8), ("solid", 0.95, 0.88)]))
    cam2 = Camera(center=(CX, 0.5), scale=0.3, dist=5.0, pitch=math.radians(24))
    vis, hid = box_edges(cam2, size=(1.4, 1.4, 1.4), rot=(0.0, math.radians(32), 0.0))
    L.append(lesson("principles.solid", "Solid Drawing", "Draw things with weight and volume.", [
        read("Think in 3D",
             "Solid drawing means drawing things as real objects with weight and volume, not flat cut-outs. Think "
             "of every shape as a box, ball or tube that you could pick up and turn around.", G(solid, fps=8)),
        trace("Draw a box", "Trace the box. See how it shows its top and two sides?",
              [ink(e) for e in vis] + [helper(e) for e in hid],
              hint="Do the three lines that meet at the front corner first.", checks=[chk_straight()]),
        quiz("Which shows solid drawing?", ["A box showing its top and two sides", "A flat square"], 0,
             "Showing more than one side gives the box volume."),
    ]))

    # 12. Appeal
    def character(t):
        # t = 0: boring (all the same size), 1: appealing (big body, small head, medium feet)
        body_r = lerp(0.12, 0.22, t)
        head_r = lerp(0.12, 0.08, t)
        foot_rx = lerp(0.12, 0.07, t)
        base = FLOOR - 0.05
        body_c = (CX, base - lerp(0.12, 0.2, t) - 0.02)
        head_c = (CX + lerp(0, 0.03, t), body_c[1] - lerp(0.12, 0.2, t) - head_r * lerp(1.0, 0.6, t))
        return [ink(ellipse(body_c[0], body_c[1], body_r, lerp(0.12, 0.2, t), n=40), closed=True),
                ink(circle(head_c[0], head_c[1], head_r, n=28), closed=True),
                ink(ellipse(CX - 0.09, base, foot_rx, 0.04, n=20), closed=True),
                ink(ellipse(CX + 0.09, base, foot_rx, 0.04, n=20), closed=True),
                ink(circle(head_c[0] - 0.03, head_c[1], 0.012, n=10), closed=True),
                ink(circle(head_c[0] + 0.03, head_c[1], 0.012, n=10), closed=True)]
    morph = [F(character(0.0), hold=12, notes=[("all the same size", CX, 0.08)])]
    for k in range(1, 9):
        morph.append(F(character(ease_in_out(k / 8))))
    morph.append(F(character(1.0), hold=16, notes=[("big, medium, small", CX, 0.08)]))
    L.append(lesson("principles.appeal", "Appeal", "Characters that are fun to look at.", [
        read("Fun to watch",
             "Appeal is what makes a character fun to look at. It doesn't just mean cute: villains need appeal too! "
             "A great trick is to mix big, medium and small shapes instead of making everything the same size.",
             G(morph)),
        trace("Big, medium, small", "Trace the character: a big body, a small head and medium feet.", character(1.0),
              hint="Start with the biggest shape, the body."),
        quiz("Which design has more appeal?",
             ["Shapes in different sizes: big, medium and small", "Every shape the same size"], 0,
             "Contrast in size makes a design interesting to look at."),
    ]))

    return course("principles", TRACK, "The 12 Principles", "The classic rules that bring drawings to life",
                  "sparkles", ["basics"], L)
