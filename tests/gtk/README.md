# GTK tests — driving the real lock screen

The unit suites test data. These drive the actual GTK stack under Xvfb, which is the
only way to catch the failures that matter on a lock screen: widgets that never map,
`show_all()` undoing a `hide()`, a crash during construction.

It has already earned its keep. Two real bugs, both shipping since at least 1.0.143:

* **the lock screen crashed on construction when the device was ALREADY admin-locked** —
  `_tick()` ran from the middle of `__init__` and touched `title_lbl` before it existed,
  so the boot lock retried sixty times and fell through to the connect window;
* **`set_no_show_all(True)` makes `show_all()` a no-op on that widget**, so the new
  message pane would have opened completely empty;
* **`show()` maps a widget but NOT its children** — 1.0.146 shipped an admin-lock screen
  with an empty button where the chat bubble should have been, because the button was
  `show()`n while its no-show-all subtree stayed unmapped. The first version of the test
  asked "is the button visible" and "does the DrawingArea object exist"; both were true
  while the operator stared at nothing. **Assert `get_mapped()` on the thing a person
  actually looks at**, and take a screenshot.

Run (from the repo root):

    docker build -t tc-gtk-test tests/gtk
    docker run --rm -v "$PWD:/src:ro" -v "$PWD/tests/gtk:/t:ro" tc-gtk-test \
      sh -c 'Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 & sleep 2; \
             DISPLAY=:99 python3 /t/lock-admin-chat.py already && \
             DISPLAY=:99 python3 /t/lock-admin-chat.py later'

`already` = the device was admin-locked before the lock screen started (a reboot while
locked). `later` = the operator was at their own lock and the administrator locked them
while they sat there. Not wired into `run-tests.sh`: it needs Docker, and that suite is
expected to run anywhere.

## Screenshots

`screenshot-lock.py` saves the real lock screen to a PNG. `PANE=1` opens the message
pane first; `TC_LOCK_SRC=/path/to/thinclient-lock` renders an older build for comparison.

    docker run --rm -v "$PWD:/src:ro" -v "$PWD/tests/gtk:/t:ro" -v /tmp:/out tc-gtk-test \
      sh -c 'Xvfb :99 -screen 0 1100x750x24 >/dev/null 2>&1 & sleep 2; \
             DISPLAY=:99 SHOT=/out/lock.png python3 /t/screenshot-lock.py'

Looking at the picture is what settled the 1.0.146 regression in seconds.
