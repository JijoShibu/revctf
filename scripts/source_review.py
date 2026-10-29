#!/usr/bin/env python3
"""Bounded Python AST hints. Reading/parsing source never imports or executes it."""
import argparse
import ast
from pathlib import Path


def review(path):
    with open(path, 'rb') as stream:
        data = stream.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024:
        return ['Source review omitted: source exceeds the 1 MiB parser budget.']
    try:
        tree = ast.parse(data, filename=str(path))
    except (SyntaxError, ValueError, RecursionError) as error:
        return ['Source could not be parsed; review the preserved text: ' + type(error).__name__]
    hints = ['Static source hints only; these are not confirmed vulnerabilities or recovered runtime values.']
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            name = node.func.id if isinstance(node.func, ast.Name) else getattr(node.func, 'attr', '')
            if name in ('open', 'read_text', 'read_bytes'):
                hints.append(f'Line {node.lineno}: external file read/open; its runtime contents may be absent from this scan.')
            elif name in ('input', 'eval', 'exec', 'split'):
                hints.append(f'Line {node.lineno}: {name} call; inspect how input is kept separate from control instructions.')
        if len(hints) >= 101:
            hints.append('Further hints omitted at the 100-hint display limit.')
            break
    return hints


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    print('\n'.join(review(args.source)))
