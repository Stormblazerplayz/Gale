#!/usr/bin/env python3
"""Builds Gale's built-in courses.

Writes Sources/GaleLearn/Resources/Courses/learn-tracks.json and one learn-course-<id>.json per course.
Every guide drawing is computed here (geometry, physics, 3D projection), never typed in by hand.

Run from anywhere:  python3 -B Modules/GaleLearn/tools/build_courses.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True

from learn_dsl import check_lesson  # noqa: E402
import courses_basics  # noqa: E402
import courses_principles  # noqa: E402
import courses_motion  # noqa: E402
import courses_3d  # noqa: E402

OUT = os.path.join(HERE, "..", "Sources", "GaleLearn", "Resources", "Courses")

TRACKS = [
    {
        "id": "animation",
        "title": "2D Animation",
        "subtitle": "From your first line to walk cycles, acting and effects",
        "symbol": "figure.walk.motion",
        "builders": [courses_basics.basics, courses_basics.tools, courses_principles.principles,
                     courses_motion.ball_course, courses_motion.walk, courses_motion.run, courses_motion.acting,
                     courses_motion.effects, courses_motion.hair],
    },
    {
        "id": "3d",
        "title": "3D in 2D",
        "subtitle": "Perspective, turnarounds, rotation and camera moves",
        "symbol": "cube.transparent",
        "builders": [courses_3d.perspective, courses_3d.turnarounds, courses_3d.rotating, courses_3d.camera,
                     courses_3d.characters],
    },
]


def main():
    os.makedirs(OUT, exist_ok=True)
    for name in os.listdir(OUT):
        if name.startswith("learn-") and name.endswith(".json"):
            os.remove(os.path.join(OUT, name))
    index = {"version": 1, "tracks": []}
    lesson_ids = set()
    total_lessons = 0
    total_bytes = 0
    for t in TRACKS:
        ids = []
        for build in t["builders"]:
            c = build()
            assert c["track"] == t["id"], c["id"]
            for lesson in c["lessons"]:
                assert lesson["id"] not in lesson_ids, lesson["id"]
                lesson_ids.add(lesson["id"])
                check_lesson(lesson)
            total_lessons += len(c["lessons"])
            data = json.dumps(c, separators=(",", ":"), ensure_ascii=False)
            path = os.path.join(OUT, "learn-course-%s.json" % c["id"])
            with open(path, "w", encoding="utf-8") as f:
                f.write(data)
                f.write("\n")
            total_bytes += len(data)
            ids.append(c["id"])
            print("  %-14s %2d lessons  %6.0f KB" % (c["id"], len(c["lessons"]), len(data) / 1024))
        index["tracks"].append({"id": t["id"], "title": t["title"], "subtitle": t["subtitle"],
                                "symbol": t["symbol"], "courses": ids})
    with open(os.path.join(OUT, "learn-tracks.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("%d lessons, %.0f KB" % (total_lessons, total_bytes / 1024))
    assert total_lessons >= 50, total_lessons


if __name__ == "__main__":
    main()
