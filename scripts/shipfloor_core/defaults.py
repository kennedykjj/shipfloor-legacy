"""The facts more than one script needs, written once (#171): deploy, report, dispatch, the dashboard and the health
history take them from here."""

# the trailer of every commit the factory's own scripts make (deploy's merge, renumber and revert; report's commit)
TRAILER = "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"

# deploy's settings when the project config does not set them (the dashboard shows these as the unset knobs)
DEPLOY_DEFAULTS = {"timeout_min": 30, "conflict_max_files": 5, "conflict_max_hunks": 20}

# stage: (queue column, columns whose cards with no live run it resumes, WIP columns), as the dispatcher runs them
STAGES = {"refine": ("Ready for Refinement", ("Technical Refinement",), ("Spec Review",)),
          "develop": ("Ready for Dev", ("Coding",), ("Coding", "Validation")),
          "validate": ("Validation", (), ()), "deploy": ("Ready for Prod", (), ())}
