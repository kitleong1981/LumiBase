#!/usr/bin/env python3
"""AX readback of a real packaged app launch. Requires macOS Automation access.
Use an explicitly isolated home; never modifies the user's production preferences.
"""
import argparse
import json
import os
import pathlib
import signal
import subprocess
import time


def apple(script):
    return subprocess.check_output(['osascript', '-e', script], text=True).strip()


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--app', required=True)
    p.add_argument('--home', required=True)
    p.add_argument('--keep-running', action='store_true')
    p.add_argument('--exercise-reopen', action='store_true')
    p.add_argument('--restore-state', action='store_true')
    p.add_argument('--direct', action='store_true')
    a = p.parse_args()
    app = pathlib.Path(a.app).resolve()
    home = pathlib.Path(a.home).resolve()
    home.mkdir(parents=True, exist_ok=True)
    name = app.stem
    # Refuse to target any pre-existing instance, including the user's app.
    query = f'tell application "System Events" to get unix id of every process whose name is "{name}"'
    if apple(query):
        raise SystemExit('Refusing: an existing app instance is running')
    launch = ['open', '-n', str(app), '--env', f'CFFIXED_USER_HOME={home}', '--env', f'HOME={home}']
    if not a.restore_state:
        # CFFIXED_USER_HOME alone does not isolate cfprefsd on every macOS.
        # Argument-domain overrides neither erase nor persist production values.
        launch += ['--args', '-ApplePersistenceIgnoreState', 'YES', '-libraryJPEGROIRadius', '2', '-libraryJPEGROIBudgetMiB', '128', '-previewSharpnessEnabled', 'YES']
    if a.direct:
        env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
        args = launch[launch.index('--args') + 1:] if '--args' in launch else []
        subprocess.Popen([str(app / 'Contents/MacOS' / name), *args], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        subprocess.run(launch, check=True)
    pid = None
    try:
        for _ in range(40):
            ids = apple(query)
            if ids:
                pid = int(ids.split(',')[0].strip())
                break
            time.sleep(.25)
        if pid is None:
            raise SystemExit('No application process appeared')
        titles = ''
        for _ in range(40):
            titles = apple(f'tell application "System Events" to tell (first process whose unix id is {pid}) to get name of every window')
            if 'LumiBase v' in titles:
                break
            time.sleep(.25)
        workspace = [x.strip() for x in titles.split(',') if 'LumiBase v' in x]
        print(json.dumps({'pid': pid, 'windows': titles, 'workspace_count': len(workspace), 'home': str(home)}))
        if len(workspace) != 1:
            raise SystemExit('Launch must create exactly one visible workspace, not only Settings')
        if a.exercise_reopen:
            target = f'tell application "System Events" to tell (first process whose unix id is {pid}) to '
            apple(target + 'click menu item "Settings…" of menu 1 of menu bar item 2 of menu bar 1')
            time.sleep(.8)
            apple(target + f'click button 1 of window "{workspace[0]}"')
            time.sleep(.5)
            only_settings = apple(target + 'get name of every window')
            print(json.dumps({'phase': 'main-closed-settings-visible', 'windows': only_settings}))
            if 'LumiBase v' in only_settings or 'Settings' not in only_settings:
                raise SystemExit('Failed to establish Settings-only reopen fixture')
            # Merely keeping Settings active must not recreate the workspace.
            time.sleep(1)
            if 'LumiBase v' in apple(target + 'get name of every window'):
                raise SystemExit('Workspace reopened without explicit reopen request')
            windows = only_settings
            for attempt in range(3):
                subprocess.run(['open', str(app)], check=True)
                time.sleep(1)
                windows = apple(target + 'get name of every window')
                print(json.dumps({'phase': 'explicit-reopen', 'attempt': attempt, 'windows': windows}))
                if windows.count('LumiBase v') != 1:
                    raise SystemExit('Explicit reopen must show one workspace even when Settings is visible')
            # No visible windows: the same standard reopen must restore workspace.
            for title in [x.strip() for x in windows.split(',')]:
                apple(target + f'click button 1 of window "{title}"')
            subprocess.run(['open', str(app)], check=True)
            time.sleep(1)
            windows = apple(target + 'get name of every window')
            print(json.dumps({'phase': 'all-closed-reopen', 'windows': windows}))
            if windows.count('LumiBase v') != 1:
                raise SystemExit('All-closed reopen must show one workspace')
    finally:
        if pid is not None and not a.keep_running:
            command = subprocess.check_output(['ps', '-p', str(pid), '-o', 'command='], text=True).strip()
            executable = app / 'Contents/MacOS' / name
            actual_executable = command.split('.app/Contents/MacOS/' + name, 1)[0] + '.app/Contents/MacOS/' + name
            if pathlib.Path(actual_executable).exists() and os.path.samefile(actual_executable, executable):
                os.kill(pid, signal.SIGTERM)


if __name__ == '__main__':
    main()
