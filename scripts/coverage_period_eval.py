"""Evaluate frozen source-only S/B/R references against offline coverage reports.

Reference schema ``fox.coverage_period_reference.v1`` has clips with id,
person_id, source_sha256, side, time_base=[numerator, denominator], cycles
({id,S:[lo,hi],B:[lo,hi],R:[lo,hi],ownership:[lo,hi]} in original integer PTS),
and predeclared intervals ({id,from,to,continuous:true}). Optional frame_pts is
the independently frozen complete source sampling clock; without it periods
and observation-supported count claims remain unknown. Only complete source cycles belong in cycles; initial/final
partials must be classified before reading model outputs.
S/B/R bracket endpoints must exist in frame_pts when supplied; ownership may use
any integer tick. Clip aliases cannot duplicate or overlap same-source/same-side
cycle or period declarations. Disjoint source windows remain separate samples.

Reports schema ``fox.coverage_period_reports.v1`` wraps clips with the same
identity fields and report={events,trace,count?,resetCounts?}, using unshifted
original-source seconds from fox-coverage-replay. Event order supplies event IDs.
No reference bracket is moved or enlarged to fit model output. Ownership is for
count attribution, not exact endpoint accuracy. completedAtSeconds is a debounce
confirmation: adjacent differences are confirmation-to-confirmation estimates.

CLI: --reference reference.json --reports reports.json --output fresh.json
The JSON artifact index binds input/evaluator bytes. Errors go to stderr as JSON.
Pure stdlib; no video, inference, counter, or live product dependencies.
"""

import argparse
from collections import Counter, defaultdict
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import sys


MAX_GAP = Fraction(3, 10)
MAX_BRACKET = Fraction(1, 5)


def require(condition, code):
    if not condition:
        raise ValueError(code)


def label(value):
    require(isinstance(value, str) and bool(value.strip()), 'invalid_identifier')
    return value


def integer(value):
    require(type(value) is int and value >= 0, 'invalid_source_pts')
    return value


def sequence(value):
    require(isinstance(value, list), 'expected_array')
    return value


def unique_ids(values):
    result = [label(v['id']) for v in sequence(values)]
    require(len(set(result)) == len(result), 'duplicate_id')
    return result


def bracket(value):
    require(isinstance(value, list) and len(value) == 2, 'invalid_bracket')
    a, b = map(integer, value)
    require(a <= b, 'reversed_bracket')
    return a, b


def time_tick(value, tick):
    require(type(value) in (int, float) and math.isfinite(value) and value >= 0,
            'invalid_report_time')
    ratio = Fraction(str(value)) / tick
    nearest = round(ratio)
    require(abs(ratio-nearest) <= Fraction(1, 1000), 'report_time_off_source_tick')
    return nearest


def number(value):
    return float(value)


def greedy_camera_clock(clock, tick):
    # Match the existing Double-valued PoseFrameCadenceGate, not a resampling grid.
    admitted = []
    previous = None
    for pts in clock:
        seconds = float(pts*tick)
        if previous is None or seconds-previous >= 1/12:
            admitted.append(pts); previous = seconds
    return admitted


def greedy_source_clock(clock, tick):
    selected = []
    for pts in clock:
        if not selected or (pts-selected[-1])*tick >= Fraction(1, 12):
            selected.append(pts)
    return selected


def observation_clocks(clip, tick, source_clock):
    if 'counter_admission_policy' not in clip:
        require('observer_input_pts' not in clip and 'input_sampling_policy' not in clip,
                'undeclared_observer_admission_policy')
        return source_clock, source_clock
    require(source_clock is not None and clip['counter_admission_policy'] == 'camera_greedy_12hz_v1',
            'invalid_counter_admission_policy')
    policy = clip.get('input_sampling_policy')
    require(policy in ('all_source_frames', 'source_greedy_12hz_v1'), 'invalid_input_sampling_policy')
    expected = source_clock if policy == 'all_source_frames' else greedy_source_clock(source_clock, tick)
    declared = sequence(clip.get('observer_input_pts'))
    require(all(type(p) is int for p in declared) and declared == expected, 'observer_input_clock_mismatch')
    return declared, greedy_camera_clock(declared, tick)


def ordered_quantile(values, probability):
    """Nearest-rank P90: never interpolate a smaller high-tail error."""
    return sorted(values)[math.ceil(probability * len(values))-1]


def validate_source(clip):
    label(clip['id']); label(clip['person_id'])
    require(clip['side'] in ('left', 'right'), 'invalid_side')
    require(isinstance(clip['source_sha256'], str) and
            re.fullmatch('[0-9a-f]{64}', clip['source_sha256']), 'invalid_source_hash')
    tb = clip['time_base']
    require(isinstance(tb, list) and len(tb) == 2 and
            all(type(x) is int and x > 0 for x in tb), 'invalid_time_base')
    tick = Fraction(*tb)
    ids = unique_ids(clip['cycles'])
    require(ids, 'empty_reference_cycles')
    cycles = []
    for raw in clip['cycles']:
        cy = {'id': raw['id'], **{key: bracket(raw[key]) for key in ('S', 'B', 'R', 'ownership')}}
        require(cy['ownership'][0] <= cy['S'][0] <= cy['S'][1] <= cy['B'][0] <=
                cy['B'][1] <= cy['R'][0] <= cy['R'][1] <= cy['ownership'][1],
                'source_SBR_order')
        require(not cycles or cy['S'][0] >= cycles[-1]['S'][0], 'source_cycle_order')
        cycles.append(cy)
    unique_ids(clip['intervals'])
    seen = set()
    for interval in clip['intervals']:
        pair = (interval['from'], interval['to'])
        require(interval.get('continuous') is True and pair not in seen and
                pair[0] in ids and pair[1] in ids and ids.index(pair[1]) == ids.index(pair[0])+1,
                'interval_not_unique_continuous_adjacent_reference')
        seen.add(pair)
        a, b = cycles[ids.index(pair[0])], cycles[ids.index(pair[1])]
        require(b['R'][0] > a['R'][1], 'nonpositive_reference_period')
    clock = clip.get('frame_pts')
    if clock is not None:
        sequence(clock)
        for i, value in enumerate(clock):
            integer(value)
            require(i == 0 or value > clock[i-1], 'source_clock_not_increasing')
        require(clock, 'empty_source_clock')
        clock_set = set(clock)
        for cy in cycles:
            for key in ('S', 'B', 'R'):
                require(all(p in clock_set for p in cy[key]), 'source_endpoint_off_clock:'+key)
    return tick, cycles, clock


def validate_source_declarations(clips):
    """Reject alias-based sample inflation using source time, not clip labels."""
    occupied = defaultdict(list)
    for clip in clips:
        tick, cycles, _ = validate_source(clip)
        by_id = {c['id']: c for c in cycles}
        spans = [(c['S'][0]*tick, c['R'][1]*tick) for c in cycles]
        spans += [(by_id[i['from']]['R'][0]*tick, by_id[i['to']]['R'][1]*tick)
                  for i in clip['intervals']]
        previous = occupied[(clip['source_sha256'], clip['side'])]
        for low, high in spans:
            for owner, a, b in previous:
                # Sharing a single boundary is allowed; repeated zero-width
                # declarations are still aliases. Normalize distinct time bases.
                require(not ((low, high) == (a, b) or max(low, a) < min(high, b)),
                        'overlapping_source_declarations:'+owner+':'+clip['id'])
        previous.extend((clip['id'], low, high) for low, high in spans)


def parse_report(wrapped, clip, tick, clock):
    if wrapped is None:
        return [], [], {}, True
    require(all(wrapped.get(k) == clip[k] for k in ('id', 'person_id', 'source_sha256', 'side')),
            'report_source_identity_mismatch')
    report = wrapped['report']
    input_clock, admitted_clock = observation_clocks(clip, tick, clock)
    explicit_admission = 'counter_admission_policy' in clip
    if explicit_admission:
        claimed = sequence(report.get('admitted_frame_pts'))
        require(all(type(p) is int for p in claimed) and claimed == admitted_clock, 'admission_clock_mismatch')
    else:
        require('admitted_frame_pts' not in report, 'undeclared_admission_clock')
    events = []
    clock_set = set(clock) if clock is not None else None
    for index, raw in enumerate(sequence(report['events'])):
        times = [time_tick(raw[k], tick) for k in
                 ('startedAtSeconds', 'lowEndpointCandidateSeconds', 'completedAtSeconds')]
        require(not events or times[2] >= events[-1]['completed'], 'event_order_not_chronological')
        if clock_set is not None:
            require(all(t in clock_set for t in times), 'event_not_on_source_clock')
        if explicit_admission:
            require(all(t in admitted_clock for t in times), 'event_not_on_admission_clock')
        events.append(dict(event_id=str(index+1), index=index, start=times[0],
                           low=times[1], completed=times[2]))
    if 'count' in report:
        require(type(report['count']) is int and report['count'] == len(events), 'report_count_integrity')
    trace = []
    for raw in sequence(report['trace']):
        pt = time_tick(raw['seconds'], tick)
        require(not trace or pt > trace[-1]['pts'], 'trace_not_increasing')
        require(clock_set is None or pt in clock_set, 'trace_not_on_source_clock')
        reason = label(raw['reason'])
        if explicit_admission:
            require(pt in input_clock, 'trace_not_on_observer_input_clock')
            require(type(raw.get('admitted')) is bool and raw['admitted'] == (pt in admitted_clock),
                    'admission_flag_mismatch')
            require(raw['admitted'] or reason == 'cadence_not_admitted', 'invalid_unadmitted_reason')
        require('reset' not in raw or type(raw['reset']) is bool, 'invalid_trace_reset')
        trace.append(dict(pts=pt, reason=reason, reset=raw.get('reset', False),
                          reset_reason=raw.get('resetReason')))
    resets = report.get('resetCounts', {})
    require(isinstance(resets, dict), 'invalid_reset_counts')
    for key, value in resets.items():
        label(key); require(type(value) is int and value >= 0, 'invalid_reset_counts')
    return events, trace, resets, False


def assess_clip(clip, wrapped):
    tick, cycles, clock = validate_source(clip)
    events, trace, resets, absent = parse_report(wrapped, clip, tick, clock)
    input_clock, admitted_clock = observation_clocks(clip, tick, clock)
    raw_trace_by_pts = {t['pts']: t for t in trace}
    if 'counter_admission_policy' in clip:
        trace = [t for t in trace if t['pts'] in admitted_clock]
        # The original source clock still validates S/B/R; continuous observation
        # uses the two independently frozen, content-blind sampling stages.
        clock = admitted_clock
    trace_reasons = Counter(t['reason'] for t in trace)
    trace_gaps = sum((b['pts']-a['pts'])*tick > MAX_GAP for a, b in zip(trace, trace[1:]))
    # Cumulative resets do not locate an interruption. If trace cannot explain a
    # reset, neither complete-event claims nor periods have continuous evidence.
    unlocated_reset = any(n > max(trace_reasons[key], trace_gaps if key == 'time_gap' else 0)
                          for key, n in resets.items())
    trace_by_pts = {t['pts']: t for t in trace}
    claims = defaultdict(list)
    for event in events:
        owners = []
        if event['start'] <= event['low'] < event['completed']:
            for cy in cycles:
                if (cy['ownership'][0] <= event['start'] and event['completed'] <= cy['ownership'][1]
                        and cy['S'][0] <= event['start'] <= cy['B'][1]
                        and cy['S'][0] <= event['low'] <= cy['B'][1]
                        and event['completed'] >= cy['B'][0]):
                    owners.append(cy['id'])
        event['candidate_cycle_ids'] = owners
        if event['start'] > event['low'] or event['low'] >= event['completed']:
            event.update(status='unknown', reason='invalid_event_order')
        elif not owners:
            event.update(status='FP', reason='no_unique_source_episode')
        elif len(owners) > 1:
            event.update(status='unknown', reason='ambiguous_source_ownership')
        else:
            claims[owners[0]].append(event)
    matched = {}
    for cid, group in claims.items():
        for event in group:
            if len(group) == 1:
                # Source ownership is necessary but cannot legitimize an event
                # that the frozen counter could not publish across a reset.
                left, right = event['start'], event['completed']
                span = [t for t in trace if left <= t['pts'] <= right]
                violations = []
                if clock is None: violations.append('source_clock_unknown')
                if left not in trace_by_pts or right not in trace_by_pts:
                    violations.append('missing_trace_boundary')
                if clock is not None and any(p not in trace_by_pts for p in clock if left <= p <= right):
                    violations.append('missing_trace_frame')
                if input_clock is not None and any(p not in raw_trace_by_pts for p in input_clock if left <= p <= right):
                    violations.append('missing_observer_input_trace_frame')
                if any(t['reason'] != 'valid' for t in span): violations.append('rejected_observation')
                if any(t['reset'] or t['reset_reason'] is not None for t in span): violations.append('trace_reset')
                if any((y['pts']-x['pts'])*tick > MAX_GAP for x, y in zip(span, span[1:])):
                    violations.append('time_gap')
                if unlocated_reset: violations.append('reset_location_unknown')
                event['observation_support_reasons'] = violations
                if violations:
                    event.update(status='unknown', reason='observation_evidence_violation')
                else:
                    event.update(status='TP', reason='unique_source_episode', cycle_id=cid)
                    matched[cid] = event
            else:
                event.update(status='unknown', reason='duplicate_cycle_claim')
    by_id = {c['id']: c for c in cycles}
    for cid, event in matched.items():
        r = by_id[cid]['R']
        event['return_residual_seconds'] = [number((event['completed']-r[1])*tick),
                                             number((event['completed']-r[0])*tick)]
    counts = Counter(e['status'] for e in events)
    count = {k: counts[k] for k in ('TP', 'FP', 'unknown')}
    count.update(FN=len(cycles)-len(matched), reference_cycles=len(cycles),
                 predicted_events=len(events), absolute_count_error=abs(len(events)-len(cycles)))

    intervals = []
    for raw in clip['intervals']:
        a, b = by_id[raw['from']], by_id[raw['to']]
        bounds = [(b['R'][0]-a['R'][1])*tick, (b['R'][1]-a['R'][0])*tick]
        qualified = all((c['R'][1]-c['R'][0])*tick <= MAX_BRACKET for c in (a, b))
        item = dict(id=raw['id'], from_cycle_id=a['id'], to_cycle_id=b['id'],
                    reference_seconds=list(map(number, bounds)), reference_qualified=qualified,
                    emitted=False, reasons=[])
        reasons = item['reasons']
        if not qualified: reasons.append('reference_precision_unknown')
        if absent: reasons.append('report_missing')
        if clock is None: reasons.append('source_clock_unknown')
        if a['id'] not in matched or b['id'] not in matched:
            reasons.append('unmatched_reference_neighbor')
        else:
            first, second = matched[a['id']], matched[b['id']]
            left, right = first['completed'], second['completed']
            if second['index'] != first['index']+1:
                reasons.append('nonadjacent_event_ids')
            if any(e['status'] != 'TP' and e['start'] <= right and e['completed'] >= left for e in events):
                reasons.append('extra_or_unknown_event_in_span')
            if right <= left: reasons.append('nonpositive_predicted_period')
            if left not in trace_by_pts or right not in trace_by_pts:
                reasons.append('missing_trace_boundary')
            span = [t for t in trace if left <= t['pts'] <= right]
            if clock is not None and any(p not in trace_by_pts for p in clock if left <= p <= right):
                reasons.append('missing_trace_frame')
            if input_clock is not None and any(p not in raw_trace_by_pts for p in input_clock if left <= p <= right):
                reasons.append('missing_observer_input_trace_frame')
            if any(t['reason'] != 'valid' for t in span): reasons.append('rejected_observation')
            if any(t['reset'] or t['reset_reason'] is not None for t in span): reasons.append('trace_reset')
            if any((y['pts']-x['pts'])*tick > MAX_GAP for x, y in zip(span, span[1:])):
                reasons.append('time_gap')
            if unlocated_reset: reasons.append('reset_location_unknown')
            if not reasons:
                predicted = (right-left)*tick
                signed = [predicted-bounds[1], predicted-bounds[0]]
                lower = max(Fraction(0), bounds[0]-predicted, predicted-bounds[1])
                item.update(emitted=True, predicted_seconds=number(predicted),
                            from_event_id=first['event_id'], to_event_id=second['event_id'],
                            signed_error_seconds=list(map(number, signed)),
                            abs_error_lower_seconds=number(lower),
                            abs_error_upper_seconds=number(max(map(abs, signed))))
        intervals.append(item)
    return dict(id=clip['id'], person_id=clip['person_id'], side=clip['side'],
                count=count, events=events,
                cycles=[dict(id=c['id'], status='TP' if c['id'] in matched else 'FN',
                             event_id=matched[c['id']]['event_id'] if c['id'] in matched else None)
                        for c in cycles], intervals=intervals)


def evaluate(reference, reports):
    require(reference['schema'] == 'fox.coverage_period_reference.v1', 'reference_schema')
    require(reports['schema'] == 'fox.coverage_period_reports.v1', 'reports_schema')
    unique_ids(reference['clips']); unique_ids(reports['clips'])
    require(reference['clips'], 'empty_reference_clips')
    report_map = {r['id']: r for r in reports['clips']}
    require(set(report_map) <= {c['id'] for c in reference['clips']}, 'unexpected_report_clip')
    hash_people = {}
    for clip in reference['clips']:
        # Identical source bytes cannot become independent people by relabeling.
        require(hash_people.setdefault(clip['source_sha256'], clip['person_id']) == clip['person_id'],
                'identical_source_relabelled_as_different_person')
    validate_source_declarations(reference['clips'])
    clips = [assess_clip(c, report_map.get(c['id'])) for c in reference['clips']]
    count = {key: sum(c['count'][key] for c in clips)
             for key in ('TP', 'FP', 'FN', 'unknown', 'reference_cycles', 'predicted_events')}
    count['precision'] = count['TP']/(count['TP']+count['FP']) if count['TP']+count['FP'] else None
    # Preserve v1 precision semantics for old readers; unknown claims are also
    # unmatched predictions in the strict delivery metric.
    count['unmatched_events'] = count['FP']+count['unknown']
    count['strict_precision'] = count['TP']/count['predicted_events'] if count['predicted_events'] else None
    count['missing_reports'] = sum(c['id'] not in report_map for c in reference['clips'])
    count['recall'] = count['TP']/count['reference_cycles']
    count['maximum_absolute_count_error_per_clip'] = max(c['count']['absolute_count_error'] for c in clips)
    intervals = [i for c in clips for i in c['intervals']]
    emitted = [i for i in intervals if i['emitted']]
    errors = [i['abs_error_upper_seconds'] for i in emitted]
    period = dict(declared_intervals=len(intervals),
                  reference_qualified_intervals=sum(i['reference_qualified'] for i in intervals),
                  emitted_intervals=len(emitted), coverage=len(emitted)/len(intervals) if intervals else None,
                  median_upper_abs_error_seconds=statistics.median(errors) if errors else None,
                  p90_upper_abs_error_seconds=ordered_quantile(errors, .9) if errors else None,
                  timing_semantics='confirmation_to_confirmation',
                  exclusion_counts=dict(Counter(r for i in intervals for r in i['reasons'])))
    role = reference.get('role', 'development')
    require(role in ('development', 'independent_acceptance'), 'invalid_evaluation_role')
    independent = sequence(reference.get('independent_untuned_person_ids', []))
    for value in independent: label(value)
    require(len(independent) == len(set(independent)), 'duplicate_independent_person_id')
    people = {c['person_id'] for c in clips}
    require(set(independent) <= people, 'unknown_independent_person_id')
    eligible = role == 'independent_acceptance' and people <= set(independent) and len(people) >= 3
    count_sample = eligible and count['reference_cycles'] >= 30
    count_pass = (count['precision'] is not None and count['precision'] >= .95 and count['recall'] >= .95
                  and count['unknown'] == 0 and count['missing_reports'] == 0 and count['maximum_absolute_count_error_per_clip'] <= 1)
    count['acceptance'] = ('passed_declared_independent_cohort' if count_pass else 'failed') if count_sample else 'development_only'
    emitted_people = {c['person_id'] for c in clips if any(i['emitted'] for i in c['intervals'])}
    qualified_people = {c['person_id'] for c in clips if any(i['reference_qualified'] for i in c['intervals'])}
    # Sample sufficiency is decided from frozen source, never model success. A
    # qualified person with zero predictions is a failed result, not lost sample.
    period_sample = eligible and period['reference_qualified_intervals'] >= 30 and len(qualified_people) >= 3
    period_pass = (count['missing_reports'] == 0 and bool(errors) and period['coverage'] >= .8 and
                   len(emitted_people) >= 3 and period['median_upper_abs_error_seconds'] <= .2
                   and period['p90_upper_abs_error_seconds'] <= .4)
    count.update(samples_sufficient=count_sample, metrics_pass=count_pass)
    period.update(samples_sufficient=period_sample, metrics_pass=period_pass,
                  reference_qualified_people=sorted(qualified_people), emitted_people=sorted(emitted_people))
    period['acceptance'] = ('passed_declared_independent_cohort' if period_pass else 'failed') if period_sample else 'development_only'
    return dict(schema='fox.coverage_period_evaluation.v1', count=count, period=period, clips=clips,
                exact_endpoint_accuracy_claim=False,
                independence_evidence='input declarations only; evaluator does not establish human identity or non-exposure')


def load_json(path):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate_json_key')
            result[key] = value
        return result
    raw = path.read_bytes()
    obj = json.loads(raw, object_pairs_hook=pairs,
                     parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite_json')))
    return obj, dict(path=str(path.resolve()), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--reports', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    stage = 'output'
    try:
        require(not args.output.exists() and not args.output.is_symlink(), 'output_exists')
        stage = 'reference'; reference, ref_index = load_json(args.reference)
        stage = 'reports'; reports, report_index = load_json(args.reports)
        stage = 'evaluate'; result = evaluate(reference, reports)
        evaluator = Path(__file__).resolve(); raw = evaluator.read_bytes()
        result['artifacts'] = dict(reference=ref_index, reports=report_index,
                                   evaluator=dict(path=str(evaluator), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest()))
        stage = 'output'
        payload = json.dumps(result, indent=2, allow_nan=False)+'\n'
        with args.output.open('x') as output:
            output.write(payload)
        print(json.dumps(dict(status='completed', output=str(args.output.resolve()),
                              count_acceptance=result['count']['acceptance'], period_acceptance=result['period']['acceptance'])))
        return 0
    except (ValueError, KeyError, TypeError, IndexError, OSError) as error:
        code = 'output_exists' if isinstance(error, FileExistsError) else str(error)
        print(json.dumps(dict(status='error', error=dict(stage=stage, code=code, type=type(error).__name__))), file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
