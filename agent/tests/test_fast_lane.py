from agents.spec import is_fast_lane


def test_simple_menu_questions_take_fast_lane():
    for q in ["What vegan options are at Crossroads for lunch?", "Best high protein dinner at Crossroads tonight?",
              "What's for dinner at Cafe 3?"]:
        assert is_fast_lane(q), q


def test_policy_and_planning_use_planner():
    for q in ["Is the pasta safe for a peanut allergy?", "Plan me a 2000 calorie day",
              "Build a meal under 600 calories", "How do swipes work?", "Any gluten free options?", "hello"]:
        assert not is_fast_lane(q), q
