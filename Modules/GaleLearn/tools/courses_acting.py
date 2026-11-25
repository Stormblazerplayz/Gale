"""Track "2D Animation": Acting, Lip Sync, and Hair & Cloth, taught in depth.

Every lesson is narrated: a watch step talks you through a real demo beat by beat (onion skin, motion trails,
timing charts, slow motion), then an "animate it" step opens the frames in Gale's real editor and talks you
through what to draw on each frame. Every drawing is computed here (faces from feelings, mouths from sounds,
hair and cloth from springs and travelling waves), never typed in by hand.
"""
import math

from learn_geo import (ASPECT, GROUND, TAU, arc, catmull, circle, ease_in_out, ellipse, lerp, lerp2, line, move,
                       walk_pose)
from learn_dsl import (F, G, accent, animate, beat, chk_loop, chk_smooth, course, helper, ink, lesson, quiz, trace,
                       watch)
from content_kit import CX, bean, eye, figure, ground, mouth
from courses_motion import ponytail_sim

TRACK = "animation"
FLOOR = GROUND


# ---------------------------------------------------------------- shared drawing helpers

def ghosted(paths, w=0.006):
    """The same drawing as faint, unscored guide lines (for parts the learner doesn't draw)."""
    out = []
    for p in paths:
        q = dict(p)
        q["role"] = "guide"
        q["w"] = w
        out.append(q)
    return out


def pts_of(path):
    f = path["pts"]
    return [(f[i], f[i + 1]) for i in range(0, len(f), 2)]


def look_eye(cx, cy, size, openness=1.0, look=0.0, big=1.0):
    """An almond eye whose pupil looks left (-1) to right (+1). openness 0 = shut, 1 = open."""
    size *= big
    if openness <= 0.02:
        return [ink(arc(cx, cy + size * 0.05, size, size * 0.35, 0, math.pi, n=16))]
    lower = arc(cx, cy, size, size * 0.55, 0, math.pi, n=16)
    upper = arc(cx, cy + size * 0.55 * (1 - openness), size, size * 0.55 * openness + 1e-3, math.pi, 2 * math.pi,
                n=16)
    out = [ink(upper + lower[1:-1] + [upper[0]])]
    if openness > 0.45:
        pr = size * 0.3 * min(1.0, openness + 0.2)
        out.append(ink(circle(cx + look * size * 0.42, cy + size * 0.06, pr, n=14), closed=True))
    return out


def brow(cx, cy, size, side, lift=0.0, tilt=0.0):
    """One eyebrow above an eye. lift > 0 raises it, tilt > 0 raises the inner end (worried), < 0 lowers it (cross)."""
    inner = (cx - side * size * 0.75, cy - size * 1.05 - lift * size - tilt * size * 0.45)
    outer = (cx + side * size * 0.85, cy - size * 0.95 - lift * size + tilt * size * 0.25)
    mid = ((inner[0] + outer[0]) / 2, (inner[1] + outer[1]) / 2 - size * 0.18)
    return ink(catmull([inner, mid, outer], per=6))


def face_features(cx, cy, r, openness=1.0, look=0.0, lift=0.0, tilt=0.0, turn=0.0, mouth_shape="rest", big=1.0,
                  mouth_scale=None):
    """Eyes, brows and mouth on a round head of radius r. turn (0..1) slides the features across as the head turns
    toward the right, and squeezes the far eye, like a simple head turn."""
    shift = turn * r * 0.42
    paths = []
    for side in (-1, 1):
        squeeze = 1 - 0.35 * turn if side == 1 else 1 - 0.1 * turn
        ex = cx + shift + side * r * 0.38 * (1 - 0.25 * turn)
        ey = cy - r * 0.15
        size = r * 0.2 * squeeze
        paths += look_eye(ex, ey, size, openness, look, big)
        paths.append(brow(ex, ey, size, side, lift, tilt))
    s = mouth_scale if mouth_scale is not None else r * 1.5
    paths += mouth(mouth_shape, cx + shift * 1.05, cy + r * 0.48, s)
    return paths


def head_ring(cx, cy, r):
    return [helper(circle(cx, cy, r, n=48), w=0.008, closed=True)]


# ---------------------------------------------------------------- Acting

def acting():
    L = []

    # 1. Line of action ---------------------------------------------------------
    def pose_on(curve_pts, base):
        """A stick pose built along a line of action (hips at the bottom, head at the top)."""
        hip = curve_pts[0]
        neck = curve_pts[-1]
        d = (neck[0] - curve_pts[-2][0], neck[1] - curve_pts[-2][1])
        ld = math.hypot(*d) or 1
        head = (neck[0] + d[0] / ld * 0.07, neck[1] + d[1] / ld * 0.07)
        sh = curve_pts[int(len(curve_pts) * 0.85)]
        arms = [[sh, (sh[0] - 0.14, sh[1] - 0.1), (sh[0] - 0.22, sh[1] - 0.22)],
                [sh, (sh[0] + 0.12, sh[1] + 0.06), (sh[0] + 0.24, sh[1])]]
        legs = [[hip, (hip[0] - 0.08, hip[1] + 0.15), (hip[0] - 0.14, base)],
                [hip, (hip[0] + 0.1, hip[1] + 0.14), (hip[0] + 0.16, base)]]
        return [ink(curve_pts), ink(circle(head[0], head[1], 0.07, n=24), closed=True)] + [ink(a) for a in arms + legs]

    def curve(kind, bend):
        pts = []
        for i in range(11):
            t = i / 10
            if kind == "C":
                x = CX - bend * math.sin(math.pi * t)
            elif kind == "S":
                x = CX + bend * math.sin(TAU * t)
            else:
                x = CX
            pts.append((x, 0.58 - 0.36 * t))
        return pts
    straight_c, c_curve, s_curve = curve("I", 0), curve("C", 0.12), curve("S", 0.07)
    loa = []
    for name, c in (("Stiff", straight_c), ("C curve", c_curve), ("S curve", s_curve)):
        loa.append(F(pose_on(c, 0.86) + [accent(c, w=0.01)], hold=14, notes=[(name, CX, 0.08)]))
    big_c = [(CX - 0.25 * math.sin(math.pi * t), 0.88 - 0.76 * t) for t in (i / 30 for i in range(31))]
    L.append(lesson("acting.pose", "Line of Action", "Strong poses flow along one line.", [
        watch("One strong line",
              "The orange line is the line of action: one clear line through the whole body.",
              G(loa, fps=12, bg=[ground()]),
              [beat("Every strong pose starts with one simple line through the whole body. It's called the line of "
                    "action.", 0, 2),
               beat("This one's stiff. A straight line, straight up and down. It's not wrong, it just feels a bit "
                    "flat.", 0, 0),
               beat("Now a C curve. The back bends, the head leans in, and suddenly there's energy in it.", 1, 1),
               beat("An S curve flows one way, then the other. It feels relaxed and graceful, like a dancer.", 2, 2),
               beat("So when you start a pose, draw the line first. Then hang the body on it.", 0, 2, ["slow"])]),
        trace("Draw the line of action", "Trace one big, confident C curve. This is where a pose starts.", [ink(big_c)],
              hint="One smooth sweep, from bottom to top. Don't stop halfway.", checks=[chk_smooth()]),
        animate("Pose to pose",
                "Three poses on three frames: stiff, then a C curve, then an S curve. Draw the line first, then the "
                "body on it.",
                [F(pose_on(c, 0.86), hold=10) for c in (straight_c, c_curve, s_curve)], fps=12, bg=[ground()],
                loop=False,
                hint="Draw the back line first on every frame. The head, arms and legs follow it.",
                tips=["Stiff. A straight back, head right on top. Draw the line, then the limbs.",
                      "The C curve. Bend the back into one big curve and lean the head into it.",
                      "The S curve. The back bends one way, then the other, like a wave."]),
        quiz("Which line of action has the most energy?", ["A curvy C or S line", "A stiff straight line"], 0,
             "Curves feel alive; straight lines feel stiff."),
    ]))

    # 2. Blinks -----------------------------------------------------------------
    HX, HY, HR = CX, 0.5, 0.34
    ring = head_ring(HX, HY, HR)
    blink_seq = [(1.0, 0.0, 12, "Open"), (0.45, -0.04, 1, None), (0.0, -0.1, 2, "Closed"), (0.35, -0.06, 1, None),
                 (0.75, -0.02, 1, None), (1.0, 0.0, 14, "Open")]

    def eyes_only(openness, lift, look=0.0):
        paths = []
        for side in (-1, 1):
            ex, ey, size = HX + side * HR * 0.38, HY - HR * 0.15, HR * 0.2
            paths += look_eye(ex, ey, size, openness, look)
            paths.append(brow(ex, ey, size, side, lift))
        return paths
    calm_mouth = mouth("rest", HX, HY + HR * 0.48, HR * 1.5)
    blink_frames = [F(eyes_only(o, lf), hold=h, notes=[(t, HX, 0.08)] if t else None) for o, lf, h, t in blink_seq]
    blink_bg = ring + ghosted(calm_mouth)
    L.append(lesson("acting.blink", "Blinks", "A blink is quick to close and a little slower to open.", [
        watch("Break down a blink",
              "A natural blink, frame by frame.",
              G(blink_frames, fps=12, bg=blink_bg),
              [beat("A blink is one of the easiest ways to make a character feel alive. Let's watch one.", 0, 5),
               beat("It closes really fast. Just one in-between, and then it's shut.", 0, 2, ["slow", "onion"]),
               beat("It stays shut for a frame or two. Any longer and it starts to look sleepy.", 2, 2),
               beat("Then it opens a bit slower than it closed. Two in-betweens on the way up.", 2, 5,
                    ["slow", "onion"]),
               beat("See how the top lid does almost all the moving? The bottom lid hardly moves at all.", 1, 3),
               beat("And here's a pro touch. The brows dip down a little as the eyes close, then lift back up.", 0, 5,
                    ["slow"]),
               beat("Blink when a character changes their mind, turns their head, or every few seconds while they "
                    "listen.", 0, 5)]),
        animate("Animate a blink",
                "Six frames, with the holds already set. Draw both eyes and brows on every frame.",
                [F(eyes_only(o, lf), hold=h) for o, lf, h, _ in blink_seq], fps=12, bg=blink_bg, loop=False,
                hint="The top lid comes down to meet the bottom one. The brows dip a little when the eyes shut.",
                tips=["Eyes open, looking straight ahead. Brows relaxed.",
                      "Half closed. The top lids slide down past the pupils.",
                      "Shut. Just two curved lines, and the brows dip down a touch.",
                      "Starting to open. The top lids lift a little.",
                      "Nearly open. The pupils peek back out.",
                      "Open again, brows back where they started."]),
        quiz("Which is faster in a normal blink?", ["Closing the eyes", "Opening the eyes"], 0,
             "Eyes snap shut quickly, then open a little slower."),
        quiz("When is a great moment to add a blink?", ["When a character turns their head or has a new thought",
                                                       "In the middle of a big shout", "Never, blinks are boring"], 0,
             "Blinks mark a change, like a new thought or a head turn."),
    ]))

    # 3. Eyes lead the head ------------------------------------------------------
    nose_y = HY + HR * 0.12

    def turned(turn, look, openness=1.0):
        paths = face_features(HX, HY, HR, openness=openness, look=look, turn=turn)
        nx = HX + turn * HR * 0.5
        paths.append(ink([(nx, nose_y - HR * 0.1), (nx + HR * 0.06 * (0.3 + turn), nose_y + HR * 0.06),
                          (nx, nose_y + HR * 0.1)]))
        return paths
    eye_keys = [(0.0, 0.0, 1.0, 10, "Looking ahead"), (0.0, 0.9, 1.0, 6, "Eyes dart"), (0.3, 0.9, 1.0, 1, None),
                (0.6, 0.6, 0.0, 1, "Blink"), (0.85, 0.4, 1.0, 1, None), (1.0, 0.25, 1.0, 14, "Head follows")]
    eye_frames = [F(turned(t, lk, o), hold=h, notes=[(n_, HX, 0.08)] if n_ else None) for t, lk, o, h, n_ in eye_keys]
    eye_track = [(HX + t * HR * 0.5, nose_y) for t, _, _, _, _ in eye_keys]
    L.append(lesson("acting.eyes", "Eyes Lead the Way", "The eyes move first, then the head follows.", [
        watch("Eyes first, head second",
              "Something catches their eye on the right.",
              G(eye_frames, fps=12, bg=ring, track=eye_track),
              [beat("Something just caught this character's attention, over on the right. Watch what moves "
                    "first.", 0, 5),
               beat("The eyes. They dart across in a single frame. Real eyes jump like that, no in-betweens.", 0, 1),
               beat("Then they hold for a moment. That little pause is the character noticing something.", 1, 1),
               beat("Now the head turns to follow, easing in and out. Everything on the face slides across "
                    "together.", 1, 5, ["onion", "slow"]),
               beat("And there's a blink right in the middle of the turn. It hides the jump and feels really "
                    "natural.", 3, 3),
               beat("By the end, the head has caught up, so the eyes drift back toward the middle.", 4, 5),
               beat("Eyes lead, the head follows, then the body. Remember that order and your acting will feel "
                    "real.", 0, 5, ["trail"])]),
        animate("Animate the eye dart and head turn",
                "Six frames: look, dart, turn, blink, turn, settle. Draw the eyes, brows, nose and mouth on every "
                "frame. The head circle is already there.",
                [F(turned(t, lk, o), hold=h) for t, lk, o, h, _ in eye_keys], fps=12, bg=ring, loop=False,
                hint="The pupils jump first. On the blink frame, the eyes are just two curves.",
                tips=["Looking straight ahead. Pupils in the middle, face in the middle.",
                      "The dart. Only the pupils move, right over to the right side.",
                      "The head starts turning. Slide the whole face a little to the right.",
                      "Blink in the middle of the turn. The eyes are closed curves.",
                      "Eyes open again, the face nearly all the way round.",
                      "The head's caught up. The pupils drift back toward the middle."]),
        quiz("When a character notices something, what moves first?", ["The eyes", "The head", "The feet"], 0,
             "Eyes lead, then the head, then the body."),
        quiz("Why put a blink in the middle of a head turn?", ["It feels natural and hides the jump",
                                                              "To make the turn slower", "It doesn't matter"], 0,
             "People really do blink as they turn, so it reads as natural."),
    ]))

    # 4. The take ---------------------------------------------------------------
    CHIN = 0.84

    def take_head(sx, sy, openness, lift, tilt, shape, big=1.0, look=0.0):
        rx, ry = 0.3 * sx, 0.3 * sy
        cy = CHIN - ry
        paths = [ink(ellipse(CX, cy, rx, ry, n=48), closed=True)]
        r = (rx + ry) / 2
        paths += face_features(CX, cy, r, openness=openness, lift=lift, tilt=tilt, mouth_shape=shape, big=big,
                               look=look)
        return paths
    take_keys = [((1.0, 1.0, 0.9, 0.0, 0.0, "rest", 1.0), 10, "Calm"),
                 ((1.14, 0.84, 0.2, -0.25, -0.2, "MBP", 1.0), 5, "Anticipation"),
                 ((0.86, 1.2, 1.0, 0.55, 0.15, "O", 1.3), 3, "Take!"),
                 ((0.95, 1.08, 1.0, 0.4, 0.1, "O", 1.18), 12, "Hold"),
                 ((1.0, 1.02, 1.0, 0.3, 0.05, "U", 1.1), 14, "Settle")]
    take_frames = [F(take_head(*a), hold=h, notes=[(n_, CX, 0.06)]) for a, h, n_ in take_keys]
    take_track = [(CX, CHIN - 0.3 * a[1] - 0.3 * a[1] * 0.15) for a, _, _ in take_keys]
    L.append(lesson("acting.take", "The Take", "A big surprised reaction: squash, stretch, hold, settle.", [
        watch("Break down a take",
              "A cartoon double take, worked out as squash and stretch on the whole head.",
              G(take_frames, fps=12, bg=[helper(line((CX - 0.12, CHIN), (CX + 0.12, CHIN)), w=0.006)],
                track=take_track),
              [beat("This is a take. It's how a cartoon character reacts to a big surprise. Watch the whole "
                    "thing.", 0, 4),
               beat("First, anticipation. The head squashes down, the eyes squeeze shut, the brows push down.", 0, 1,
                    ["slow", "onion"]),
               beat("Then, pop! It stretches up tall. Brows shoot up, eyes go huge, the mouth drops open.", 1, 2,
                    ["slow", "onion"]),
               beat("Now hold it. The audience needs a moment to read the expression. Don't rush this part.", 2, 3),
               beat("Then it settles back down, but stays a little surprised. It doesn't snap back to calm.", 3, 4,
                    ["slow"]),
               beat("Squash before, stretch for the hit, hold, then settle. The bigger the squash, the bigger the "
                    "take.", 0, 4, ["trail"])]),
        animate("Animate a take",
                "Five key poses with the holds already set. Draw the head shape and the face on every frame.",
                [F(take_head(*a), hold=h) for a, h, _ in take_keys], fps=12,
                bg=[helper(line((CX - 0.12, CHIN), (CX + 0.12, CHIN)), w=0.006)], loop=False,
                hint="The head stays the same size overall. Squashed is short and wide, stretched is tall and thin.",
                tips=["Calm. A round head, relaxed brows, a soft closed mouth.",
                      "Anticipation. Squash the head short and wide, eyes squeezed, brows down.",
                      "The take! Stretch the head tall and thin, huge eyes, brows way up, mouth open.",
                      "Hold. Still surprised, just a little less stretched.",
                      "Settle. Nearly round again, eyes still big, mouth a small O."]),
        quiz("What comes right before the big stretch of a take?", ["A squash", "Another stretch", "Nothing"], 0,
             "The squash is the anticipation that makes the stretch pop."),
        quiz("Why hold the take for a moment?", ["So the audience can read the expression", "To save drawings"], 0,
             "A held pose gives people time to see the feeling."),
    ]))

    # 5. Breathing and moving holds ------------------------------------------------
    nb = 8
    breath = [1.0 + 0.06 * math.sin(TAU * k / nb) for k in range(nb)]
    bh, bw = 0.46, 0.27
    breath_frames = [F(bean(CX, FLOOR, h=bh, w=bw, squash=s), notes=[("Breathe in", CX, 0.08)] if k == 2 else
                       ([("Breathe out", CX, 0.08)] if k == 6 else None))
                     for k, s in enumerate(breath)]
    breath_track = [(CX, FLOOR - bh * s) for s in breath]
    L.append(lesson("acting.breath", "Breathing & Moving Holds", "A still character is never totally frozen.", [
        watch("Alive, even when still",
              "A gentle breathing loop: the body rises and falls a tiny bit.",
              G(breath_frames, fps=6, bg=[ground()], track=breath_track),
              [beat("Even when a character is just standing there, they're breathing. Watch the top of the "
                    "bean.", 0, nb - 1),
               beat("Breathing in, the body stretches up a little and gets slimmer.", 0, 2, ["onion", "slow"]),
               beat("Breathing out, it settles back down and gets a touch wider.", 4, 6, ["onion", "slow"]),
               beat("It's tiny. If you can really see it, it's too much. It should feel alive, not like it's "
                    "bouncing.", 0, nb - 1, ["trail"]),
               beat("Animators call this a moving hold. Use it whenever a character holds a pose for more than a "
                    "second.", 0, nb - 1)]),
        animate("Animate a breathing loop",
                "Eight frames that loop. Draw the bean on every frame, rising and falling just a little.",
                [F(bean(CX, FLOOR, h=bh, w=bw, squash=s)) for s in breath], fps=6, bg=[ground()],
                checks=[chk_loop()],
                hint="Keep the feet on the ground. Only the top rises and falls.",
                tips=["The middle of the breath. The normal bean.",
                      "Breathing in. A tiny bit taller and slimmer.",
                      "The top of the breath. The tallest it gets.",
                      "Starting to breathe out. Coming back down.",
                      "Back to the middle again.",
                      "Breathing out. A tiny bit shorter and wider.",
                      "The bottom of the breath. The shortest it gets.",
                      "Coming back up. Then it loops to frame 1."]),
        quiz("A character holds still for three seconds. You should...",
             ["Keep a tiny bit of movement, like breathing", "Freeze every drawing completely"], 0,
             "A moving hold keeps them looking alive."),
    ]))

    return course("acting", TRACK, "Acting", "Strong poses, blinks, eye darts, takes and breathing", "face.smiling",
                  ["principles"], L)


# ---------------------------------------------------------------- Lip Sync

def lipsync():
    L = []
    FX, FY, FR = CX, 0.47, 0.36
    MYc, MS = FY + FR * 0.45, FR * 1.15

    def face_bg(cx=FX, cy=FY, r=FR):
        bg = [helper(circle(cx, cy, r, n=48), w=0.008, closed=True)]
        for side in (-1, 1):
            bg += ghosted(eye(cx + side * r * 0.38, cy - r * 0.18, r * 0.2, 1.0))
        return bg
    fb = face_bg()

    # 1. The mouth chart -----------------------------------------------------------
    chart = [("rest", "Rest"), ("A", "A, as in cat"), ("E", "E, as in see"), ("O", "O, as in go"),
             ("U", "U, as in you"), ("MBP", "M, B, P"), ("FV", "F, V"), ("L", "L, T, D, N, TH")]
    chart_frames = [F(mouth(m, FX, MYc, MS), hold=10, notes=[(w, FX, 0.04)]) for m, w in chart]
    big = 2.0
    L.append(lesson("lipsync.shapes", "The Mouth Chart", "Eight mouths that cover almost every sound.", [
        watch("Meet the mouths",
              "Say each sound out loud while you watch. Feel what your own mouth does.",
              G(chart_frames, fps=12, bg=fb),
              [beat("Here's the secret of lip sync. You don't draw letters, you draw sounds. And eight mouths cover "
                    "nearly all of them.", 0, 7),
               beat("Rest. Lips together and relaxed. This goes in the gaps between words.", 0, 0),
               beat("A, like in cat or father. The jaw drops and the mouth opens wide. It's the biggest shape.", 1, 1),
               beat("E, like in see. Wide and a bit flat, and you can see the top teeth.", 2, 2),
               beat("O, like in go, is round and open. U, like in you, is the same idea, just smaller and "
                    "tighter.", 3, 4),
               beat("M, B and P press the lips together. You can't say them with your mouth open. Try it!", 5, 5),
               beat("F and V tuck the top teeth onto the bottom lip. You can feel the air buzz.", 6, 6),
               beat("And L lifts the tongue up behind the teeth. It works for T, D, N and TH too.", 7, 7),
               beat("Grab a mirror and say each one. Every animator does this, even the pros.", 0, 7, ["slow"])]),
        trace("A", "Trace the A mouth: the jaw dropped, wide open.", mouth("A", FX, 0.5, big),
              hint="The big open shape, the tongue at the bottom, and the line of the top teeth.", tolerance=0.035,
              accuracy=0.75),
        trace("M B P", "Trace the M B P mouth: lips pressed together.", mouth("MBP", FX, 0.5, big),
              hint="The top lip, the bottom lip and the line where they meet.", tolerance=0.035, accuracy=0.75),
        trace("F V", "Trace the F V mouth: top teeth resting on the bottom lip.", mouth("FV", FX, 0.5, big),
              hint="The lip shape first, then the box of the teeth.", tolerance=0.035, accuracy=0.75),
        quiz("Which mouth do you use for the B in \"ball\"?", ["Lips pressed together", "Wide open", "Teeth on lip"],
             0, "M, B and P all start with the lips pressed shut."),
    ]))

    # 2. Listen first -------------------------------------------------------------
    hello_there = [("rest", 6, ""), ("E", 3, "he"), ("L", 2, "l"), ("O", 5, "lo"), ("rest", 2, ""),
                   ("L", 2, "th"), ("E", 6, "ere"), ("rest", 10, "")]
    ht = [F(mouth(m, FX, MYc, MS), hold=h, notes=[(t, FX, 0.04)] if t else None) for m, h, t in hello_there]
    L.append(lesson("lipsync.listen", "Listen First", "Break a line into sounds and count the frames.", [
        watch("Break down \"Hello there\"",
              "Each mouth is labelled with the sound it makes. The holds are counted at 12 frames a second.",
              G(ht, fps=12, bg=fb, loop=False),
              [beat("Before you draw a single mouth, listen. Let's break down, hello there.", 0, 7),
               beat("Say it slowly. Hel, low, there. Now listen for the sounds, not the spelling.", 0, 7, ["slow"]),
               beat("He is an E sound. Then the L, which lifts the tongue. Then a big round O.", 1, 3, ["onion"]),
               beat("There starts with TH. The tongue touches the teeth, so we use the L mouth. Then E, held "
                    "long.", 5, 6),
               beat("Count the frames. At twelve frames a second, a quick sound gets two frames. A vowel you lean on "
                    "gets five or six.", 0, 7, ["slow"]),
               beat("And there's a tiny rest between the words. Real speech has little gaps like that.", 4, 4),
               beat("Pros write all this down on a chart before they animate. Sounds, then frames. Then "
                    "drawings.", 0, 7)]),
        quiz("At 12 frames a second, how many frames is one second?", ["12", "24", "6"], 0,
             "12 frames a second means 12 drawings, or holds, for every second."),
        quiz("The TH in \"there\" uses which mouth?", ["L, with the tongue up", "M B P, lips shut", "O, round"], 0,
             "The tongue touches the teeth, just like L, T, D and N."),
        quiz("Which sounds get held the longest?", ["Vowels you lean on, like the O in hello",
                                                    "Quick sounds like T and K"], 0,
             "Vowels are the long, open sounds."),
    ]))

    # 3. Say hello ----------------------------------------------------------------
    hello = [("rest", 6), ("E", 3), ("L", 2), ("O", 6), ("rest", 10)]
    say = [F(mouth(m, FX, MYc, MS), hold=h,
             notes=[({"E": "he", "L": "l", "O": "lo", "rest": ""}[m] or "...", FX, 0.04)]) for m, h in hello]
    L.append(lesson("lipsync.hello", "Say Hello", "Your first word, start to finish.", [
        watch("Hello, frame by frame",
              "Rest, E, L, O, rest.",
              G(say, fps=12, bg=fb, loop=False),
              [beat("Time for your first word. Hello! Watch and listen first.", 0, 4),
               beat("It starts from rest. Then E for the he, nice and wide.", 0, 1),
               beat("The L is quick. Just two frames with the tongue up.", 2, 2),
               beat("Then the big O, held the longest. That's the part of the word you really hear.", 3, 3),
               beat("And back to rest. Not too fast though, let the mouth close gently.", 3, 4, ["slow"])]),
        animate("Animate \"hello\"",
                "Five frames, holds already set. Draw the mouth on every frame over the guide, then press play.",
                [F(mouth(m, FX, MYc, MS), hold=h) for m, h in hello], fps=12, bg=fb, loop=False,
                hint="E is wide and flat. L shows the tongue. O is round.",
                tips=["Rest. A soft, closed mouth.",
                      "E, for the he. Wide and a bit flat, with the teeth showing.",
                      "L. Open a little and lift the tongue up behind the teeth.",
                      "O. A round, open mouth. This one's held the longest.",
                      "Rest again. Close the mouth gently. Now press play!"]),
        quiz("In \"hello\", which mouth is held the longest?", ["The O at the end", "The L", "The E"], 0,
             "The O is the long vowel you lean on."),
    ]))

    # 4. The jaw drops ------------------------------------------------------------
    JX, JY, JR = CX, 0.42, 0.3
    openness = {"rest": 0.0, "MBP": 0.0, "U": 0.25, "O": 0.6, "A": 1.0, "E": 0.35, "L": 0.45, "FV": 0.15}

    def jaw_head(shape):
        drop = 0.1 * openness[shape]
        jaw = catmull([(JX - JR, JY), (JX - JR * 0.88, JY + JR * 0.6 + drop * 0.45),
                       (JX - JR * 0.42, JY + JR * 0.92 + drop), (JX, JY + JR * 1.0 + drop),
                       (JX + JR * 0.42, JY + JR * 0.92 + drop), (JX + JR * 0.88, JY + JR * 0.6 + drop * 0.45),
                       (JX + JR, JY)], per=6)
        return [ink(jaw)] + mouth(shape, JX, JY + JR * 0.55 + drop * 0.6, JR * 1.6)
    jaw_bg = [helper(arc(JX, JY, JR, JR, math.pi, TAU, n=40), w=0.008)]
    for side in (-1, 1):
        jaw_bg += ghosted(eye(JX + side * JR * 0.38, JY - JR * 0.1, JR * 0.2, 1.0))
    wow = [("rest", 6, ""), ("U", 2, "w"), ("A", 5, "ow"), ("U", 3, "w"), ("rest", 3, ""), ("L", 2, "l"),
           ("U", 4, "oo"), ("rest", 10, "k")]
    jaw_frames = [F(jaw_head(m), hold=h, notes=[(t, JX, 0.05)] if t else None) for m, h, t in wow]
    jaw_track = [(JX, JY + JR + 0.1 * openness[m]) for m, _, _ in wow]
    L.append(lesson("lipsync.jaw", "The Jaw Drops", "Open sounds drop the whole jaw, not just the lips.", [
        watch("Say \"Wow, look\"",
              "Watch the chin. It drops on the open sounds and comes back up on the closed ones.",
              G(jaw_frames, fps=12, bg=jaw_bg, track=jaw_track, loop=False),
              [beat("Here's something beginners miss. When you talk, your whole jaw moves, not just your lips. "
                    "Let's say, wow, look.", 0, 7),
               beat("Watch the chin. On the W, the lips push forward into a small U. The jaw barely moves.", 1, 1),
               beat("Then the ow. The jaw drops right down for the big A. See the chin move?", 1, 2,
                    ["slow", "onion"]),
               beat("Back up to a U for the end of wow. The jaw closes again.", 2, 3, ["onion"]),
               beat("Look starts with L, then a small oo, then the K closes it off.", 5, 7, ["slow"]),
               beat("Follow the dot. The jaw goes up and down with the sounds, like it's chewing the words.", 0, 7,
                    ["trail", "chart"]),
               beat("If your lip sync looks like a puppet, check the jaw. A moving chin makes it feel real.", 0,
                    7)]),
        animate("Animate the jaw",
                "Eight frames, holds already set. On every frame, draw the jaw line and the mouth. The top of the "
                "head is already there.",
                [F(jaw_head(m), hold=h) for m, h, _ in wow], fps=12, bg=jaw_bg, loop=False,
                hint="Big open sounds drop the chin lower. Closed sounds bring it back up.",
                tips=["Rest. The jaw closed, a relaxed mouth.",
                      "W. Lips pushed into a small round U. The chin hardly moves.",
                      "Ow. Drop the chin down and open the mouth wide for the A.",
                      "W again. Bring the chin back up to a small U.",
                      "A quick rest between the words.",
                      "L. A little open, with the tongue up.",
                      "Oo. A small round U, the chin nearly closed.",
                      "K, then rest. The jaw closes and the mouth relaxes."]),
        quiz("On a big open sound like the A in \"wow\", the chin...", ["Drops down", "Stays still", "Goes up"], 0,
             "Open vowels drop the whole jaw."),
    ]))

    # 5. A full line --------------------------------------------------------------
    line_ = [("rest", 6, ""), ("A", 4, "I"), ("E", 2, ""), ("rest", 1, "c"), ("A", 4, "an"), ("L", 2, "d"),
             ("U", 2, "r"), ("A", 7, "aw!"), ("rest", 10, "")]
    full = [F(mouth(m, FX, MYc, MS), hold=h, notes=[(t, FX, 0.04)] if t else None) for m, h, t in line_]
    L.append(lesson("lipsync.line", "A Full Line", "Put it together: \"I can draw!\"", [
        watch("Break down \"I can draw!\"",
              "A whole line of dialogue, sound by sound.",
              G(full, fps=12, bg=fb, loop=False),
              [beat("Let's do a whole line. I can draw! Listen to it first.", 0, 8),
               beat("I is really two sounds glued together. Ah, then ee. So that's an A, then a quick E.", 1, 2,
                    ["onion"]),
               beat("Can. The C is a quick closed sound, just one frame. Then the A, and the N tucks into the next "
                    "word.", 3, 5),
               beat("Draw. The D lifts the tongue, the R pushes the lips into a small U, then a big open aw.", 5, 7,
                    ["slow"]),
               beat("Draw is the important word, so it gets the biggest mouth and the longest hold. That's called an "
                    "accent.", 7, 7),
               beat("Then rest. Let the mouth close softly, and hold it so the line can land.", 7, 8, ["slow"])]),
        animate("Animate \"I can draw!\"",
                "Nine frames, holds already set. Draw the mouth on every frame, then press play and say it along "
                "with your animation.",
                [F(mouth(m, FX, MYc, MS), hold=h) for m, h, _ in line_], fps=12, bg=fb, loop=False,
                hint="A is wide open, E is wide and flat, L shows the tongue, U is small and round.",
                tips=["Rest, before they speak.",
                      "Ah, the start of I. Open it wide.",
                      "Ee, the end of I. Wide and flat.",
                      "The C. Just one quick frame, nearly closed.",
                      "A, in can. Wide open again.",
                      "The N and D. Open a little, tongue up.",
                      "The R. Push the lips into a small round U.",
                      "Aw! The biggest, longest mouth. This is the accent.",
                      "Rest. Close it softly and hold."]),
        quiz("The most important word in a line usually gets...", ["The biggest mouth and the longest hold",
                                                                  "The smallest mouth", "No mouth at all"], 0,
             "That's the accent: it's what the line is really about."),
        quiz("The word \"I\" is made of which two sounds?", ["Ah, then ee", "Oh, then oo", "Just one sound"], 0,
             "Say it slowly: ah-ee."),
    ]))

    return course("lipsync", TRACK, "Lip Sync", "Mouth shapes, listening, the jaw and full lines of dialogue",
                  "mouth", ["principles"], L)


# ---------------------------------------------------------------- Hair & Cloth

def hair():
    L = []

    # 1. Hair follows -------------------------------------------------------------
    n = 30
    xs = []
    for k in range(n):
        xs.append(0.35 + 0.55 * ease_in_out(k / 9) if k < 10 else 0.9)
    hy, hr = 0.35, 0.12
    tails = ponytail_sim(xs, hy, hr)
    follow = [F([ink(circle(x, hy, hr, n=36), closed=True), ink(catmull(t, per=3))]) for x, t in zip(xs, tails)]
    ftrack = [t[-1] for t in tails]
    after = list(range(10, n))
    over = max(after, key=lambda k: tails[k][-1][0] - xs[k])
    back = min(range(over, n), key=lambda k: tails[k][-1][0] - xs[k])
    picks = [0, 5, 9, over, back, n - 1]
    L.append(lesson("hair.follow", "Hair Follows", "Hair drags behind, overshoots, then settles.", [
        watch("Drag, overshoot, settle",
              "The ponytail is worked out like a chain on a spring.",
              G(follow, fps=12, track=ftrack),
              [beat("Hair is stuck on at the roots, but the rest is loose. So it never moves at exactly the same time "
                    "as the head.", 0, n - 1),
               beat("As the head speeds up, the ponytail drags behind. It's being pulled along by the root.", 0, 9,
                    ["onion", "slow"]),
               beat("The head stops here. But the hair has its own speed now, so it keeps going.", 9, 12, ["slow"]),
               beat("It swings past the head, then back the other way, a little less each time.", over, back,
                    ["trail"]),
               beat("Look closely. The bend travels down the hair from the root to the tip, one joint after another. "
                    "Pros call that successive breaking of joints.", 9, back, ["onion", "slow"]),
               beat("Then it hangs still. The tip is always the last part to stop.", back, n - 1),
               beat("So that's drag, overshoot, and settle. Hair, tails, ears, scarves, they all follow the same "
                    "rule.", 0, n - 1, ["trail"])]),
        animate("Animate the follow through",
                "Six key frames: still, speeding up, stopping, swing past, swing back, rest. Draw the head and the "
                "ponytail on every frame.",
                [F([ink(circle(xs[k], hy, hr, n=36), closed=True), ink(catmull(tails[k], per=3))], hold=h)
                 for k, h in zip(picks, (4, 3, 3, 3, 3, 8))], fps=12, loop=False,
                hint="Draw the head first, then the ponytail from the root to the tip. The tip moves the most.",
                tips=["Still. The head on the left, the ponytail hanging straight down.",
                      "Speeding up. The head moves right and the hair drags out behind it.",
                      "The head stops. The hair is still trailing, it hasn't caught up yet.",
                      "Swing past. The hair flies forward, past the head.",
                      "Swing back. It comes back the other way, but not as far.",
                      "Rest. Hanging straight down again."]),
        quiz("When a character stops suddenly, their ponytail...", ["Keeps swinging, then settles", "Stops instantly",
                                                                    "Points straight up"], 0,
             "Loose things carry on moving: that's follow through."),
        quiz("Which part of the hair stops last?", ["The tip", "The root", "They all stop together"], 0,
             "The root is fixed to the head; the tip is the loosest part."),
    ]))

    # 2. Bouncy hair --------------------------------------------------------------
    nbh = 8
    BX, BY, BR = CX, 0.36, 0.13

    def bob(t):
        return 0.035 * math.sin(TAU * t / nbh)

    def pigtail(k, side):
        cy = BY + bob(k)
        root = (BX + side * BR * 0.92, cy + BR * 0.25)
        pts = [root]
        for i in range(1, 6):
            # Each joint follows the head a little later (successive breaking), and swings a little more.
            lag = 0.55 * i
            rest_x = root[0] + side * (0.016 * i + 0.002 * i * i)
            rest_y = root[1] + 0.06 * i
            pts.append((rest_x + side * 0.005 * i * math.cos(TAU * (k - lag) / nbh),
                        rest_y + (bob(k - lag) - bob(k)) * (1 + 0.12 * i)))
        return catmull(pts, per=4)

    def bouncy(k):
        cy = BY + bob(k)
        return [ink(circle(BX, cy, BR, n=40), closed=True), ink(pigtail(k, -1)), ink(pigtail(k, 1))]
    bouncy_frames = [F(bouncy(k)) for k in range(nbh)]
    bouncy_track = [pigtail(k, 1)[-1] for k in range(nbh)]
    L.append(lesson("hair.bounce", "Bouncy Hair", "Pigtails bob along, a beat behind the head.", [
        watch("Pigtails on a bounce",
              "The head bobs up and down, like when someone walks. The pigtails follow late.",
              G(bouncy_frames, fps=8, track=bouncy_track),
              [beat("Here's a head bobbing up and down, like it's walking. Watch the pigtails.", 0, nbh - 1),
               beat("When the head goes up, the pigtails get left behind for a moment. They're heavy, so they "
                    "lag.", 0, 2, ["onion", "slow"]),
               beat("When the head comes down, the pigtails are still on their way up, then they flop down "
                    "late.", 4, 7, ["onion", "slow"]),
               beat("Follow the tip. It moves more than the root, and a little after it.", 0, nbh - 1, ["trail"]),
               beat("This little delay is overlap. It turns a stiff head into one that feels soft and bouncy.", 0,
                    nbh - 1)]),
        animate("Animate bouncy pigtails",
                "Eight frames that loop. Draw the head and both pigtails on every frame.",
                [F(bouncy(k)) for k in range(nbh)], fps=8, checks=[chk_loop()],
                hint="Draw the head first. The pigtail tips are always a step behind the head.",
                tips=["The middle of the bob. Head and pigtails at rest.",
                      "The head rises. The pigtails start to get left behind.",
                      "The head at its highest. The tips are still low, lagging behind.",
                      "The head starts down. Now the tips are swinging up.",
                      "Back to the middle. The tips are at their highest.",
                      "The head drops. The tips are still up, about to flop.",
                      "The head at its lowest. The tips are on their way down.",
                      "Coming back up. Then it loops to frame 1."]),
        quiz("The head goes up. Where are the pigtail tips?", ["Still low, lagging behind", "Already at the top"], 0,
             "Loose parts follow a little later."),
    ]))

    # 3. Hair in the wind ---------------------------------------------------------
    nw = 6
    WX, WY, WR = 0.9, 0.42, 0.12

    def strand(k, a0, ph, length_=0.52, amp=0.045, spread=0.03):
        root = (WX + WR * math.cos(a0), WY + WR * math.sin(a0))
        pts = []
        for i in range(13):
            u = i / 12
            # A wave travels from the root to the tip, and it gets bigger toward the loose end.
            y = root[1] + spread * u + amp * u * math.sin(TAU * (1.3 * u - k / nw) + ph)
            pts.append((root[0] - length_ * u, y))
        return pts

    def windy(k):
        return [ink(circle(WX, WY, WR, n=40), closed=True),
                ink(strand(k, math.radians(200), 0.0, spread=-0.04)),
                ink(strand(k, math.radians(170), 0.9, length_=0.48, spread=0.04)),
                ink(strand(k, math.radians(145), 1.8, length_=0.42, amp=0.04, spread=0.12))]
    wind_frames = [F(windy(k)) for k in range(nw)]
    wind_track = [strand(k, math.radians(200), 0.0, spread=-0.04)[-1] for k in range(nw)]
    L.append(lesson("hair.wind", "Hair in the Wind", "Waves roll down the hair from the root to the tip.", [
        watch("Wind in the hair",
              "Three locks of hair blowing back. Each one is a wave travelling from the head to the tip.",
              G(wind_frames, fps=8, track=wind_track),
              [beat("Wind is blowing from the right, so the hair streams out to the left.", 0, nw - 1),
               beat("Look at one lock. The wave starts at the head and rolls all the way out to the tip.", 0, nw - 1,
                    ["onion", "slow"]),
               beat("The roots hardly move. The tips flick the most. That's what makes it feel light.", 0, nw - 1,
                    ["trail"]),
               beat("And each lock is a little out of step with the others. If they all wave together, it looks "
                    "like one stiff sheet.", 0, nw - 1, ["slow"]),
               beat("The last frame flows straight back into the first, so the wind can blow forever.", 0,
                    nw - 1)]),
        animate("Animate hair in the wind",
                "Six frames that loop. Draw the head and the three locks of hair on every frame.",
                [F(windy(k)) for k in range(nw)], fps=8, checks=[chk_loop()],
                hint="Keep the roots still. Move the wave a little further toward the tip on each frame.",
                tips=["The head and three locks blowing back. Notice where each wave is.",
                      "Move every wave a little further out toward the tips.",
                      "Further again. The bumps keep rolling out.",
                      "The tips flick as the waves reach them.",
                      "New waves start back near the head.",
                      "Nearly back where you started. It loops to frame 1."]),
        quiz("In the wind, which way do the waves travel along the hair?", ["From the root to the tip",
                                                                            "From the tip to the root"], 0,
             "The head holds the root, so the waves start there and roll out."),
        quiz("Should every lock of hair wave exactly together?", ["No, a little out of step looks natural",
                                                                  "Yes, all at the same time"], 0,
             "Offsetting them stops it looking like one stiff sheet."),
    ]))

    # 4. Waving flag --------------------------------------------------------------
    pole_x, top_y, bot_y, flag_w = 0.3, 0.2, 0.5, 0.75

    def flag(t, n_=24):
        def off(u):
            return 0.06 * u * math.sin(TAU * (1.2 * u - t))
        top = [(pole_x + flag_w * u, top_y + off(u) + 0.02 * u) for u in (i / n_ for i in range(n_ + 1))]
        bottom = [(pole_x + flag_w * u, bot_y + off(u) - 0.01 * u) for u in (i / n_ for i in range(n_ + 1))]
        return top + list(reversed(bottom))
    pole = [helper(line((pole_x, 0.12), (pole_x, 0.92)), w=0.012)]
    nf = 6
    flag_frames = [F([ink(flag(k / 12), closed=True)]) for k in range(12)]
    flag_track = [flag(k / 12)[24] for k in range(12)]
    L.append(lesson("hair.flag", "Waving Flag", "Waves travel along the cloth.", [
        watch("How a flag waves",
              "The pole holds one edge still. Waves run out to the free end.",
              G(flag_frames, fps=12, bg=pole, track=flag_track),
              [beat("A flag is cloth held still along one edge, at the pole. Everything else is free.", 0, 11),
               beat("The wind sends waves along it, from the pole out to the free end. Watch a bump travel.", 0, 11,
                    ["onion", "slow"]),
               beat("Near the pole the cloth barely moves. The free corner flaps the most.", 0, 11, ["trail"]),
               beat("The top and bottom edges wave together, so the whole flag ripples like one piece of "
                    "cloth.", 0, 11, ["slow"])]),
        animate("Animate a waving flag",
                "Six frames that loop. Draw the flag on every frame. The pole is already there.",
                [F([ink(flag(k / nf), closed=True)]) for k in range(nf)], fps=8, bg=pole, checks=[chk_loop()],
                hint="The edge at the pole never moves. Move each wave a little further out each frame.",
                tips=["The flag with its waves. The pole edge stays straight.",
                      "Shift every wave a little away from the pole.",
                      "A little further again.",
                      "The free corner flips as a wave reaches it.",
                      "A new wave starts by the pole.",
                      "Almost back to frame 1, so it loops smoothly."]),
        quiz("Which way do the waves travel on a flag?", ["From the pole to the free end",
                                                          "From the free end to the pole"], 0,
             "The pole holds one end, so the waves start there and run outward."),
    ]))

    # 5. Capes and scarves ----------------------------------------------------------
    def caped(t):
        pose = walk_pose(t, run=True, hip_x=0.8)
        neck = pose["torso"][1]
        hip = pose["torso"][0]
        sh = lerp2(hip, neck, 0.95)
        length_ = 0.42
        top_edge = []
        bot_edge = []
        for i in range(13):
            u = i / 12
            wv = 0.035 * u * math.sin(TAU * (1.5 * u - t))
            top_edge.append((sh[0] - length_ * u, sh[1] + 0.02 + 0.1 * u * u + wv))
            bot_edge.append((sh[0] - 0.02 - length_ * u * 0.95, sh[1] + 0.18 + 0.12 * u + wv))
        return pose, top_edge + list(reversed(bot_edge))
    cape_watch = []
    for k in range(8):
        pose, cape = caped(k / 8)
        cape_watch.append(F(figure(pose) + [ink(cape, closed=True)]))
    cape_track = [caped(k / 8)[1][12] for k in range(8)]
    n_cape = 4
    cape_anim = []
    for k in range(n_cape):
        pose, cape = caped(k / n_cape)
        cape_anim.append(F(ghosted(figure(pose)) + [ink(cape, closed=True)]))
    L.append(lesson("hair.cape", "Capes & Scarves", "Cloth that drags and ripples behind a runner.", [
        watch("A cape on a run",
              "A runner with a cape. The cape is attached at the shoulders.",
              G(cape_watch, fps=10, bg=[ground()], track=cape_track),
              [beat("A cape is like hair and a flag mixed together. It's pinned at the shoulders and free at the "
                    "end.", 0, 7),
               beat("The runner pushes through the air, so the cape flies out flat behind them.", 0, 7, ["onion"]),
               beat("Waves ripple from the shoulders to the tip, just like on a flag.", 0, 7, ["slow", "trail"]),
               beat("The faster the run, the flatter it flies. Slow down, and it droops and swings more.", 0, 7),
               beat("It also bobs with the body, a little behind. Every step jiggles the cloth.", 0, 7,
                    ["slow"])]),
        animate("Animate the cape",
                "Four frames that loop. The runner is a faint guide; draw just the cape on every frame.",
                cape_anim, fps=8, bg=[ground()], checks=[chk_loop()],
                hint="Start every cape at the shoulders. Move the ripple toward the tip each frame.",
                tips=["Start at the shoulders and sweep the cape out behind, with a ripple in it.",
                      "The ripple moves further toward the tip.",
                      "Further again, and the tip flicks.",
                      "A new ripple starts by the shoulders. It loops to frame 1."]),
        quiz("What makes a cape fly flatter behind a character?", ["Moving faster", "Moving slower", "Standing still"],
             0, "More speed means more wind pushing the cape back."),
    ]))

    # 6. Cloth that lands -----------------------------------------------------------
    # A bean in a skirt drops to the floor. Air pushes the skirt up while it falls; when the bean lands, the
    # skirt keeps going, drops past its rest shape, springs back a little, then settles (a damped spring).
    falls = [0.58, 0.67, 0.78]
    lifts = []
    lift, vel = 0.2, 0.0
    seq = []
    for k in range(9):
        landed = k >= len(falls)
        target = 0.0 if landed else 0.55
        vel = vel * 0.45 + (target - lift) * (0.65 if landed else 0.5)
        lift += vel
        lifts.append(lift)
        seq.append(FLOOR if landed else falls[k])
    keep = [0, 1, 2, 3, 4, 5, 6, 8]
    holds = [1, 1, 1, 1, 2, 2, 2, 10]

    def skirted(base, lift_, squash=1.0):
        bh_, bw_ = 0.5, 0.3
        body = bean(CX, base, h=bh_, w=bw_, squash=squash)
        waist = base - bh_ * squash * 0.36
        hem_drop = 0.15 * (1 - 0.6 * lift_)
        flare = 0.19 + 0.1 * max(0.0, lift_) - 0.04 * max(0.0, -lift_)
        top_w = bw_ / math.sqrt(squash) * 0.56
        hem_y = waist + hem_drop
        hem = []
        for i in range(9):
            u = i / 8
            x = lerp(CX + flare, CX - flare, u)
            hem.append((x, hem_y + 0.018 * math.sin(TAU * 2 * u) * (0.4 + abs(lift_))))
        skirt = [(CX - top_w, waist), (CX + top_w, waist)] + hem
        return ghosted(body), ink(skirt, closed=True)
    land_frames = []
    land_watch = []
    land_track = []
    for idx, h in zip(keep, holds):
        squash = 0.86 if idx == len(falls) else 1.0
        body, sk = skirted(seq[idx], lifts[idx], squash)
        land_frames.append(F(body + [sk], hold=h))
        land_watch.append(F(body + [sk], hold=h, notes=[("Land", CX, 0.08)] if idx == len(falls) else None))
        hem_pts = pts_of(sk)
        land_track.append(hem_pts[len(hem_pts) // 2 + 1])
    L.append(lesson("hair.land", "Cloth That Lands", "Cloth floats as it falls, then drops, bounces and settles.", [
        watch("A skirt on landing",
              "A bean in a skirt drops to the floor. Only the skirt is worked out as loose cloth.",
              G(land_watch, fps=12, bg=[ground()], track=land_track),
              [beat("Watch the skirt as this little bean drops down and lands.", 0, 7),
               beat("While it falls, air pushes up under the cloth, so the skirt floats up and flares out.", 0, 2,
                    ["onion", "slow"]),
               beat("The body lands, but the skirt is still floating. It hasn't got the message yet.", 3, 3),
               beat("Then it drops, right past where it normally hangs. It goes too far down.", 3, 4, ["slow"]),
               beat("It springs back up a little, then down again, a bit less each time, until it rests.", 4, 7,
                    ["trail", "slow"]),
               beat("Hair, capes, skirts and ears all do this. Up on the fall, past the rest on the landing, then "
                    "settle.", 0, 7)]),
        animate("Animate the skirt",
                "Eight frames, holds already set. The bean is a faint guide; draw just the skirt on every frame.",
                land_frames, fps=12, bg=[ground()], loop=False, tolerance=0.04, accuracy=0.75,
                hint="Falling, the hem floats up and flares. After landing it drops too low, bounces, then settles.",
                tips=["Falling. The hem is lifted a little by the air.",
                      "Falling faster. The skirt floats up higher and flares out.",
                      "Almost down. The skirt is at its floatiest.",
                      "The landing. The body squashes, but the skirt is still up.",
                      "The skirt drops past its rest. Make it hang a bit too low and narrow.",
                      "It springs back up a little.",
                      "A smaller dip down again.",
                      "Settled. The skirt hangs at its normal shape."]),
        quiz("While a character falls, a loose skirt...", ["Floats up and flares out", "Hugs tight to the legs",
                                                           "Stays exactly the same"], 0,
             "Air pushes up under the cloth as it falls."),
        quiz("Just after landing, the cloth...", ["Drops past its rest, then bounces and settles",
                                                  "Stops the moment the feet touch"], 0,
             "Cloth keeps moving after the body stops: follow through."),
    ]))

    return course("hair", TRACK, "Hair & Cloth", "Follow through, bouncy hair, wind, flags, capes and landings",
                  "wind", ["principles"], L)
