"""Check explicit Lean call frames from final compiler IR; no cycle exemptions."""

import argparse
import collections
import json
import itertools
import subprocess
import sys

# These primitives store or read elements; they do not invoke them. The contract
# comes from Lean 4.33.1 runtime/object.cpp and include/lean/lean.h.
ARRAY_DATA = {"Array." + n for n in (
    "getInternalBorrowed", "mk", "push", "toList", "mkEmpty", "uset",
    "ugetBorrowed", "set", "getInternal", "replicate", "uget",
    "emptyWithCapacity", "get!Internal", "get!InternalBorrowed", "pop",
    "swapIfInBounds", "set!", "size", "usize")}
NAT_ARITHMETIC = {"Nat." + n for n in ("add", "sub", "mul", "succ", "pred", "div", "mod")}
TOP = float("inf")


class Flow:
    def __init__(self, data):
        self.decls = {d['name']: d for d in data['decls']}
        self.roots = data['roots']
        self.cells = {}
        self.values = []
        self.watch = []
        self.constraints = []
        self.queue = collections.deque()
        self.queued = set()
        self.tokens = []
        self.token_ids = {}
        self.active = set()
        self.graph = collections.defaultdict(set)
        self.applies = {}
        self.copies = set()
        self.empty = set()
        self.unknown = self.token(('unknown',), ('unknown',))
        self.problems = collections.defaultdict(set)
        self.edges = set()
        self.numbers = []
        self.increases = []
        self.constants = {}
        self.operations = {}
        self.cell_keys = []
        self.local_sources = collections.defaultdict(set)

    def cell(self, key):
        if key not in self.cells:
            self.cells[key] = len(self.values)
            self.values.append(set())
            self.watch.append(set())
            self.numbers.append(-1)  # bottom: no execution has supplied a value
            self.increases.append(0)
            self.cell_keys.append(key)
        return self.cells[key]

    def var(self, owner, var):
        return self.cell((owner, var))

    def enqueue(self, c):
        if c not in self.queued:
            self.queued.add(c)
            self.queue.append(c)

    def add(self, cell, values):
        if cell in self.empty:
            return
        new = values - self.values[cell]
        if new:
            self.values[cell].update(new)
            for c in self.watch[cell]:
                self.enqueue(c)

    def number(self, cell, bound):
        if bound > self.numbers[cell]:
            self.increases[cell] += 1
            # Widen growing loop counters to unknown. This only loses precision.
            self.numbers[cell] = TOP if self.increases[cell] > 16 else bound
            for c in self.watch[cell]:
                self.enqueue(c)

    def constraint(self, kind, args, inputs):
        c = len(self.constraints)
        self.constraints.append((kind, args))
        for cell in inputs:
            self.watch[cell].add(c)
        self.enqueue(c)

    def copy(self, source, target):
        if (source, target) not in self.copies:
            self.copies.add((source, target))
            self.constraint('copy', (source, target), [source])

    def token(self, key, value):
        if key not in self.token_ids:
            self.token_ids[key] = len(self.tokens)
            self.tokens.append(value)
        return self.token_ids[key]

    def call(self, owner, target, args, result, loop=False, site=None, closure_origin=False, guards=()):
        declaration = self.decls[target]
        # Keep generic forwarding code in its caller's context. A closure returns
        # to its creation context, so separate interpreters do not share captures.
        # All anchors are physical call sites: the context domain is finite.
        instance = ((target, site) if closure_origin else owner if loop else
                    (target, owner[1] if any(self.decls[owner[0]]['closure_params']) or
                     self.decls[owner[0]]['generic'] else site))
        if not loop:
            self.graph[owner].add(instance)
        # Tail loops still constrain ranking: they may reset a later call's fuel.
        self.edges.add((owner, instance, tuple(args), tuple(map(tuple, guards)), loop))
        self.activate(instance)
        for parameter, argument in zip(declaration['params'], args):
            self.copy(argument, self.var(instance, parameter))
        if declaration['external']:
            if target not in NAT_ARITHMETIC:
                self.number(result, TOP)
        else:
            self.copy(self.var(instance, 'return'), result)
        if declaration['external'] and (target.startswith('Nat.') or target == 'panicCore'):
            if target == 'panicCore':
                self.copy(args[-2], result)
            elif target in NAT_ARITHMETIC:
                # Arithmetic needs per-call values, not a merged extern return.
                self.constraint('arithmetic', (target, args, result), args)
        if declaration['external'] and target in ARRAY_DATA:
            if declaration['closure_return']:
                self.constraint('foreign', (instance, args, result), args + [result])
        elif declaration['external'] and target != 'panicCore':
            if declaration['closure_return']:
                self.add(result, {self.unknown})
            possible = [a for a, tracked in zip(args, declaration['closure_params']) if tracked]
            self.constraint('escape', (owner, possible, target), possible)

    def activate(self, name):
        if name in self.active:
            return
        self.active.add(name)
        d = self.decls[name[0]]
        for p, tracked in zip(d['params'],d['closure_params']):
            if not tracked:
                self.empty.add(self.var(name, p))
        if not d['closure_return']:
            self.empty.add(self.var(name, 'return'))
        if d['missing']:
            self.problems[name].add('missing compiled body')
            self.add(self.var(name, 'return'), {self.unknown})
            self.number(self.var(name, 'return'), TOP)
            return
        if d['external']:
            return
        joins = {x['join']: x['params'] for x in d['body'] if 'join' in x}
        for index, item in enumerate(d['body']):
            if 'let' in item:
                out = self.var(name, item['let'])
                v = item['value']
                args = [self.var(name, a) for a in v.get('args', [])]
                op = v['op']
                self.operations[out] = (name, v, item['guards'])
                if op == 'call':
                    self.call(name, v['target'], args, out, item['loop'], (name[0], index), guards=item['guards'])
                elif op == 'closure':
                    t = self.token((name, index), ('closure', v['target'], args, name[1]))
                    self.add(out, {t})
                    self.number(out, TOP)
                elif op == 'ctor':
                    t = self.token((name, index), ('object', dict(enumerate(args))))
                    self.constraint('construct', (t, args, out), args)
                    self.number(out, TOP)
                elif op == 'copy':
                    source = self.var(name, v['value'])
                    self.local_sources[out].add(source)
                    self.copy(source, out)
                elif op == 'proj':
                    obj = self.var(name, v['object'])
                    self.constraint('project', (obj, v['index'], out), [obj])
                    self.number(out, TOP)
                elif op == 'apply':
                    fn = self.var(name, v['fn'])
                    site = (name, index)
                    self.applies[site] = fn
                    self.constraint('apply', (site, fn, args, out), [fn])
                elif op == 'number':
                    self.constants[out] = v['value']
                    self.number(out, v['value'])
                elif op in ('string', 'scalar'):
                    self.number(out, TOP)
                else:
                    raise ValueError('Unsupported IR operation: ' + op)
            elif 'set' in item:
                obj = self.var(name, item['set'])
                value = self.var(name, item['value'])
                t = self.token((name, index), ('object', {item['index']: value}))
                self.constraint('construct', (t, [value], obj), [value])
                # Expanded reset/reuse stores update a unique constructor. Old
                # and new fields are joined; retaining old fields overapproximates.
                # Lean's reference-counting pass owns the no-live-alias invariant.
            elif 'return' in item:
                self.copy(self.var(name, item['return']), self.var(name, 'return'))
            elif 'jump' in item:
                for p, a in zip(joins[item['jump']], item['args']):
                    source, dest = self.var(name, a), self.var(name, p)
                    self.local_sources[dest].add(source)
                    self.copy(source, dest)

    def apply(self, site, token, args, out):
        info = self.tokens[token]
        if info[0] == 'unknown':
            self.problems[site[0]].add('unresolved callback')
            self.add(out, {self.unknown})
            self.number(out, TOP)
            return
        if info[0] != 'closure':
            return
        _, target, captured, origin = info
        bound = captured + args
        arity = len(self.decls[target]['params'])
        if len(bound) < arity:
            key = ('partial', site, target, origin, len(bound))
            parameters = [self.cell((key, i)) for i in range(len(bound))]
            for source, dest in zip(bound, parameters):
                self.copy(source, dest)
            t = self.token(key, ('closure', target, parameters, origin))
            self.add(out, {t})
        elif len(bound) == arity:
            self.call(site[0], target, bound, out, site=origin, closure_origin=True)
        else:
            key = ('over', site, target, origin, len(bound))
            intermediate = self.cell(key)
            self.call(site[0], target, bound[:arity], intermediate, site=origin, closure_origin=True)
            # Cache this constraint independently of the flow iterations.
            if key not in self.token_ids:
                self.token_ids[key] = -1
                self.constraint('apply', (site, intermediate, bound[arity:], out), [intermediate])

    def solve(self):
        for root in self.roots:
            owner = (root, None)
            self.activate(owner)
            for p in self.decls[root]['params']:
                self.add(self.var(owner, p), {self.unknown})
                self.number(self.var(owner, p), TOP)
        while self.queue:
            c = self.queue.popleft()
            self.queued.remove(c)
            kind, args = self.constraints[c]
            if kind == 'copy':
                source, target = args
                self.add(target, self.values[source])
                self.number(target, self.numbers[source])
            elif kind == 'construct':
                token, fields, out = args
                if any(self.values[f] for f in fields):
                    self.add(out, {token})
            elif kind == 'project':
                obj, index, out = args
                for token in list(self.values[obj]):
                    info = self.tokens[token]
                    if info[0] == 'object' and index in info[1]:
                        self.copy(info[1][index], out)
                    elif info[0] == 'carrier':
                        self.copy(info[1], out)
                    elif info[0] == 'unknown':
                        self.add(out, {self.unknown})
            elif kind == 'apply':
                site, fn, arguments, out = args
                for token in list(self.values[fn]):
                    self.apply(site, token, arguments, out)
            elif kind == 'foreign':
                name, parameters, out = args
                for p in parameters + [out]:
                    for token in list(self.values[p]):
                        info = self.tokens[token]
                        if info[0] == 'object':
                            for field in info[1].values():
                                self.copy(field, out)
                        elif info[0] == 'carrier':
                            self.copy(info[1], out)
                        else:
                            self.add(out, {token})
                if self.values[out]:
                    token = self.token(('carrier', out), ('carrier', out))
                    self.add(out, {token})
            elif kind == 'escape':
                owner, parameters, target = args
                if any(self.values[p] for p in parameters):
                    self.problems[owner].add('foreign callback or container: ' + target)
            elif kind == 'arithmetic':
                operation, inputs, out = args
                bounds = [self.numbers[p] for p in inputs]
                if min(bounds) < 0:
                    continue
                if operation == 'Nat.sub':
                    value = max(0, bounds[0] - (literal(self, inputs[1]) or 0))
                elif operation == 'Nat.pred':
                    value = max(0, bounds[0] - 1)
                elif operation == 'Nat.succ':
                    value = bounds[0] + 1
                elif operation == 'Nat.add':
                    value = sum(bounds)
                elif operation == 'Nat.mul':
                    value = 0 if 0 in bounds else bounds[0] * bounds[1]
                else:
                    value = bounds[0]  # Nat division/modulus never exceed the dividend.
                self.number(out, value)
        for site, cell in self.applies.items():
            if not any(self.tokens[t][0] in ('closure', 'unknown') for t in self.values[cell]):
                self.problems[site[0]].add('callback has no resolved target')
        for root in self.roots:
            if self.values[self.var((root, None), 'return')]:
                self.problems[(root, None)].add('export returns a function or function container')


def components(graph, nodes):
    """Tarjan SCCs. Nodes are finite compiler/context pairs."""
    counter = itertools.count()
    indices, low, stack, pending, result = {}, {}, [], set(), []
    def visit(node):
        indices[node] = low[node] = next(counter)
        stack.append(node)
        pending.add(node)
        for target in graph.get(node, ()):
            if target not in indices:
                visit(target)
                low[node] = min(low[node], low[target])
            elif target in pending:
                low[node] = min(low[node], indices[target])
        if low[node] == indices[node]:
            group = set()
            while True:
                member = stack.pop()
                pending.remove(member)
                group.add(member)
                if member == node:
                    break
            result.append(group)
    for node in nodes:
        if node not in indices:
            visit(node)
    return result


def literal(flow, cell, seen=frozenset()):
    if cell in flow.constants:
        return flow.constants[cell]
    if cell in seen or cell not in flow.local_sources:
        return None
    values = {literal(flow, source, seen | {cell}) for source in flow.local_sources[cell]}
    return next(iter(values)) if len(values) == 1 and None not in values else None


def relation(flow, owner, cell, parameter, guards, seen=frozenset()):
    """Nonincrease (0) or strict decrease (1) from one caller Nat parameter."""
    if cell == flow.var(owner, parameter):
        return 0
    if cell in seen:
        return None
    if cell in flow.local_sources:
        values = {relation(flow, owner, source, parameter, guards, seen | {cell})
                  for source in flow.local_sources[cell]}
        return min(values) if values and None not in values else None
    if cell not in flow.operations:
        return None
    seen = seen | {cell}
    context, operation, _ = flow.operations[cell]
    if context != owner:
        return None
    if operation['op'] == 'copy':
        return relation(flow, owner, flow.var(owner, operation['value']), parameter, guards, seen)
    if operation['op'] == 'call' and operation['target'] == 'Nat.sub':
        left, right = [flow.var(owner, a) for a in operation['args']]
        if relation(flow, owner, left, parameter, guards, seen) != 0:
            return None
        amount = literal(flow, right)
        if amount is None:
            return None
        if amount == 0:
            return 0
        for discr, constructor in guards:
            condition = flow.operations.get(flow.var(owner, discr))
            if condition is None:
                continue
            test = condition[1]
            if test['op'] != 'call' or test['target'] != 'Nat.decEq' or constructor != 'Bool.false':
                continue
            a, b = [flow.var(owner, v) for v in test['args']]
            if (a == left and literal(flow, b) == 0) or (b == left and literal(flow, a) == 0):
                return 1
        return 0  # truncated subtraction is nonincreasing even at zero
    return None


def certify_component(flow, group):
    internal = [e for e in flow.edges if e[0] in group and e[1] in group]
    candidates = {}
    for node in group:
        d = flow.decls[node[0]]
        candidates[node] = [p for p, nat in zip(d['params'], d['nat_params'])
                            if nat and 0 <= flow.numbers[flow.var(node, p)] < TOP]
        if not candidates[node]:
            return None
    # Remove incompatible parameter choices before trying a ranking assignment.
    changed = True
    while changed:
        changed = False
        for owner, target, args, guards, _ in internal:
            target_params = flow.decls[target[0]]['params']
            pairs = {(p, q) for p in candidates[owner] for q in candidates[target]
                     if relation(flow, owner, args[target_params.index(q)], p, guards) is not None}
            for node, allowed in ((owner, {p for p, _ in pairs}), (target, {q for _, q in pairs})):
                keep = [p for p in candidates[node] if p in allowed]
                if not keep:
                    return None
                if keep != candidates[node]:
                    candidates[node] = keep
                    changed = True
    nodes = sorted(group, key=str)
    # A precision budget must reject, never accept, when search is exhausted.
    for attempt, choice in enumerate(itertools.product(*(candidates[n] for n in nodes))):
        if attempt == 4096:
            return None
        ranking = dict(zip(nodes, choice))
        weak = collections.defaultdict(set)
        valid = True
        for owner, target, args, guards, loop in internal:
            p = flow.decls[target[0]]['params'].index(ranking[target])
            decrease = relation(flow, owner, args[p], ranking[owner], guards)
            if decrease is None:
                valid = False
                break
            if decrease == 0 and not loop:
                weak[owner].add(target)
        if valid and all(len(c) == 1 and next(iter(c)) not in weak[next(iter(c))]
                         for c in components(weak, nodes)):
            bound = max(flow.numbers[flow.var(n, ranking[n])] for n in nodes)
            return {'fuel_bound': bound, 'frame_bound': (bound + 1) * len(nodes)}
    return None


def report(flow):
    groups = components(flow.graph, flow.active)
    membership = {node: i for i, group in enumerate(groups) for node in group}
    cycles = {}
    for i, group in enumerate(groups):
        if len(group) > 1 or next(iter(group)) in flow.graph[next(iter(group))]:
            cycles[i] = certify_component(flow, group)
    reports = []
    for root in flow.roots:
        seen, todo = set(), [(root, None)]
        while todo:
            node = todo.pop()
            if node in seen:
                continue
            seen.add(node)
            todo.extend(flow.graph[node])
        reachable_groups = {membership[n] for n in seen}
        bad = [sorted({n[0] for n in groups[i]}) for i in reachable_groups if i in cycles and cycles[i] is None]
        unknown = sorted({f'{n[0]}: {reason}' for n in seen for reason in flow.problems[n]})
        bounded = [dict(functions=sorted({n[0] for n in groups[i]}), **cycles[i])
                   for i in reachable_groups if i in cycles and cycles[i] is not None]
        cost = {}
        def frames(i):
            if i not in cost:
                own = cycles[i]['frame_bound'] if i in cycles else int(not all(flow.decls[n[0]]['external'] for n in groups[i]))
                children = {membership[t] for n in groups[i] for t in flow.graph[n] if membership[t] != i}
                cost[i] = own + max((frames(j) for j in children), default=0)
            return cost[i]
        reports.append({'entrypoint': root, 'status': 'unproved' if bad or unknown else 'bounded',
                        'max_lean_frames': None if bad or unknown else frames(membership[(root, None)]),
                        'unbounded_components': bad, 'unresolved': unknown, 'bounded_components': bounded})
    return {'compiler': '4.33.1', 'exports': reports}


def main():
    parser = argparse.ArgumentParser(description='Reject unbounded recursion in compiled Lean exports.')
    parser.add_argument('--module', default='VerifiedKernel.Native')
    parser.add_argument('--prefix', default='VerifiedKernel')
    parser.add_argument('--entry')
    args = parser.parse_args()
    command = ['lake', 'env', 'lean', '--run', 'scripts/recursion-ir.lean',
               '--module', args.module, '--prefix', args.prefix]
    if args.entry:
        command += ['--entry', args.entry]
    compiled = subprocess.run(command, capture_output=True, text=True)
    if compiled.returncode:
        print(compiled.stdout + compiled.stderr, file=sys.stderr)
        return 2
    data = json.loads(compiled.stdout)
    flow = Flow(data)
    flow.solve()
    result = report(flow)
    print(json.dumps(result, indent=2))
    return int(any(e['status'] != 'bounded' for e in result['exports']))


if __name__ == '__main__':
    sys.setrecursionlimit(20000)
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RecursionError, MemoryError) as error:
        print(f'Recursion check could not complete: {error}', file=sys.stderr)
        sys.exit(2)
