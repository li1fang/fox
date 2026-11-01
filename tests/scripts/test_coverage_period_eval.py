import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/coverage_period_eval.py'
spec = importlib.util.spec_from_file_location('coverage_period_eval', SCRIPT)
e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e)


def fixture(n=3, person='person-1', clip='clip-1'):
    cycles = []
    events = []
    for i in range(n):
        b = i * 3000
        cycles.append({'id': f'cycle-{i+1}', 'S': [b, b+100], 'B': [b+1000, b+1100],
                       'R': [b+2000, b+2100], 'ownership': [b, b+2990]})
        events.append({'startedAtSeconds': (b+200)/1000,
                       'lowEndpointCandidateSeconds': (b+900)/1000,
                       'completedAtSeconds': (b+2100)/1000})
    pts = list(range(0, n*3000, 100))
    source_clip = {'id': clip, 'person_id': person,
                   'source_sha256': hashlib.sha256((person+clip).encode()).hexdigest(),
                   'side': 'right', 'time_base': [1, 1000], 'cycles': cycles,
                   'frame_pts': pts,
                   'intervals': [{'id': f'period-{i+1}', 'from': cycles[i]['id'],
                                  'to': cycles[i+1]['id'], 'continuous': True}
                                 for i in range(n-1)]}
    report_clip = {k: source_clip[k] for k in ['id', 'person_id', 'source_sha256', 'side']}
    report_clip['report'] = {'count': len(events), 'events': events, 'resetCounts': {},
                           'trace': [{'seconds': p/1000, 'reason': 'valid'} for p in pts]}
    return ({'schema': 'fox.coverage_period_reference.v1', 'role': 'development',
             'independent_untuned_person_ids': [], 'clips': [source_clip]},
            {'schema': 'fox.coverage_period_reports.v1', 'clips': [report_clip]})


class CoveragePeriodEvalTests(unittest.TestCase):
    def test_missing_result_cannot_pass_as_a_small_zero_prediction_group(self):
        source={'schema':'fox.coverage_period_reference.v1','role':'independent_acceptance','independent_untuned_person_ids':[],'clips':[]}
        reports={'schema':'fox.coverage_period_reports.v1','clips':[]}
        for i,n in enumerate([15,15,1]):
            ref,rep=fixture(n,person='independent-'+str(i),clip='clip-'+str(i))
            source['clips']+=ref['clips'];source['independent_untuned_person_ids'].append('independent-'+str(i))
            if i<2:reports['clips']+=rep['clips']
        result=e.evaluate(source,reports)
        self.assertEqual(result['count']['reference_cycles'],31)
        self.assertEqual(result['count']['FN'],1)
        self.assertEqual(result['count']['acceptance'],'failed')
        self.assertEqual(result['count']['missing_reports'],1)

    def sampled(self):
        source,reports=fixture(2)
        clip=source['clips'][0];report=reports['clips'][0]['report']
        # Source references retain the complete 20Hz source clock; inference input and
        # camera admission are independent content-blind greedy stages.
        clip['frame_pts']=list(range(0,6000,50))
        clip['observer_input_pts']=list(range(0,6000,100))
        clip['input_sampling_policy']='source_greedy_12hz_v1'
        clip['counter_admission_policy']='camera_greedy_12hz_v1'
        report['admitted_frame_pts']=clip['observer_input_pts'].copy()
        for row in report['trace']:row['admitted']=True
        return source,reports

    def test_frozen_two_stage_clock_keeps_original_endpoint_brackets_without_faking_valid(self):
        source,reports=self.sampled()
        result=e.evaluate(source,reports)
        self.assertEqual(result['count']['TP'],2)
        self.assertEqual(result['count']['strict_precision'],1)
        # An arbitrary successful-frame subset is not an admission policy.
        reports['clips'][0]['report']['admitted_frame_pts'].remove(1000)
        with self.assertRaisesRegex(ValueError,'admission_clock'):
            e.evaluate(source,reports)

    def test_missing_admitted_trace_and_hidden_input_frame_cannot_support_count(self):
        source,reports=self.sampled()
        reports['clips'][0]['report']['trace']=[r for r in reports['clips'][0]['report']['trace'] if r['seconds']!=1]
        result=e.evaluate(source,reports)
        self.assertEqual(result['count']['TP'],1)
        self.assertEqual(result['count']['unknown'],1)
        self.assertEqual(result['count']['strict_precision'],.5)
        source,reports=self.sampled()
        source['clips'][0]['observer_input_pts'].remove(1000)
        with self.assertRaisesRegex(ValueError,'observer_input_clock'):
            e.evaluate(source,reports)

    def test_cadence_skip_is_explicit_and_cannot_hide_rejected_admitted_frame(self):
        source,reports=fixture(2)
        clip=source['clips'][0];report=reports['clips'][0]['report']
        clip['frame_pts']=list(range(0,6000,50));clip['observer_input_pts']=clip['frame_pts'].copy()
        clip['input_sampling_policy']='all_source_frames';clip['counter_admission_policy']='camera_greedy_12hz_v1'
        report['admitted_frame_pts']=list(range(0,6000,100))
        report['trace']=[dict(seconds=p/1000,admitted=p%100==0,reason='valid' if p%100==0 else 'cadence_not_admitted') for p in clip['frame_pts']]
        self.assertEqual(e.evaluate(source,reports)['count']['TP'],2)
        report['trace'][20]['reason']='missing_required_joint'
        self.assertEqual(e.evaluate(source,reports)['count']['unknown'],1)
        report['trace'][20]['admitted']=False
        with self.assertRaisesRegex(ValueError,'admission_flag'):
            e.evaluate(source,reports)

    def test_exact_source_sampling_and_double_camera_policy_are_distinct_at_12hz_boundary(self):
        clock=list(range(0,12000,1000));tick=e.Fraction(1,12000)
        clip=dict(observer_input_pts=clock,input_sampling_policy='source_greedy_12hz_v1',counter_admission_policy='camera_greedy_12hz_v1')
        observer,admitted=e.observation_clocks(clip,tick,clock)
        self.assertEqual(observer,clock)
        self.assertNotEqual(admitted,clock)

    def test_all_count_gate_witnesses_must_be_actual_admitted_frames(self):
        for key in ['startedAtSeconds','lowEndpointCandidateSeconds','completedAtSeconds']:
            source,reports=fixture(2)
            clip=source['clips'][0];clip['frame_pts']=list(range(0,6000,50))
            clip['observer_input_pts']=clip['frame_pts'].copy();clip['input_sampling_policy']='all_source_frames'
            clip['counter_admission_policy']='camera_greedy_12hz_v1'
            report=reports['clips'][0]['report'];report['admitted_frame_pts']=list(range(0,6000,100))
            report['trace']=[dict(seconds=p/1000,admitted=p%100==0,reason='valid' if p%100==0 else 'cadence_not_admitted') for p in clip['frame_pts']]
            report['events'][0][key]+=.05
            with self.assertRaisesRegex(ValueError,'event_not_on_admission_clock'):
                e.evaluate(source,reports)

    def test_nonzero_one_to_one_preserves_denominator_and_bracket_bounds(self):
        source, reports = fixture()
        result = e.evaluate(source, reports)
        self.assertEqual(result['count']['TP'], 3)
        self.assertEqual(result['count']['FN'], 0)
        self.assertEqual(result['count']['FP'], 0)
        self.assertEqual(result['period']['declared_intervals'], 2)
        self.assertEqual(result['period']['emitted_intervals'], 2)
        interval = result['clips'][0]['intervals'][0]
        self.assertEqual(interval['reference_seconds'], [2.9, 3.1])
        self.assertEqual(interval['signed_error_seconds'], [-0.1, 0.1])
        self.assertAlmostEqual(interval['abs_error_upper_seconds'], .1)
        self.assertEqual(result['count']['acceptance'], 'development_only')
        self.assertEqual(result['period']['acceptance'], 'development_only')

    def test_early_confirmation_counts_without_becoming_exact_return_truth(self):
        source, reports = fixture()
        for event in reports['clips'][0]['report']['events']:
            event['completedAtSeconds'] -= .3
        result = e.evaluate(source, reports)
        self.assertEqual(result['count']['TP'], 3)
        event = result['clips'][0]['events'][0]
        self.assertEqual(event['return_residual_seconds'], [-.3, -.2])
        self.assertEqual(result['period']['timing_semantics'], 'confirmation_to_confirmation')
        self.assertFalse(result['exact_endpoint_accuracy_claim'])

    def test_missed_middle_cycle_never_creates_a_six_second_period(self):
        source, reports = fixture()
        report = reports['clips'][0]['report']
        report['events'].pop(1); report['count'] = 2
        result = e.evaluate(source, reports)
        self.assertEqual(result['count']['TP'], 2)
        self.assertEqual(result['count']['FN'], 1)
        self.assertEqual(result['period']['declared_intervals'], 2)
        self.assertEqual(result['period']['emitted_intervals'], 0)
        self.assertEqual(result['period']['coverage'], 0)

    def test_a_short_missing_frame_and_a_rejected_joint_each_break_period(self):
        for mode in ['missing', 'rejected', 'gap', 'reset']:
            with self.subTest(mode=mode):
                source, reports = fixture(2)
                trace = reports['clips'][0]['report']['trace']
                if mode == 'missing':
                    trace[:] = [t for t in trace if t['seconds'] != 2.5]
                elif mode == 'rejected':
                    next(t for t in trace if t['seconds'] == 2.5)['reason'] = 'missing_required_joint'
                elif mode == 'gap':
                    trace[:] = [t for t in trace if not 2.3 <= t['seconds'] <= 2.7]
                else:
                    next(t for t in trace if t['seconds'] == 2.5)['reset'] = True
                result = e.evaluate(source, reports)
                self.assertEqual(result['count']['TP'], 2)
                self.assertEqual(result['period']['emitted_intervals'], 0)
                self.assertEqual(result['period']['declared_intervals'], 1)

    def test_count_claim_crossing_rejection_missing_frame_or_reset_is_unknown(self):
        for mode, expected in [('reject', 'rejected_observation'),
                               ('missing', 'missing_trace_frame'), ('reset', 'trace_reset')]:
            with self.subTest(mode=mode):
                source, reports = fixture()
                trace = reports['clips'][0]['report']['trace']
                # Inside event 1's start=.2 .. complete=2.1, not just between events.
                if mode == 'reject':
                    next(t for t in trace if t['seconds'] == .5)['reason'] = 'missing_required_joint'
                elif mode == 'missing':
                    trace[:] = [t for t in trace if t['seconds'] != .5]
                else:
                    next(t for t in trace if t['seconds'] == .5)['reset'] = True
                result = e.evaluate(source, reports)
                self.assertEqual(result['count']['reference_cycles'], 3)
                self.assertEqual((result['count']['TP'], result['count']['FN'],
                                  result['count']['unknown']), (2, 1, 1))
                claim = result['clips'][0]['events'][0]
                self.assertEqual(claim['candidate_cycle_ids'], ['cycle-1'])
                self.assertEqual(claim['reason'], 'observation_evidence_violation')
                self.assertIn(expected, claim['observation_support_reasons'])
                self.assertEqual(result['period']['declared_intervals'], 2)
                self.assertEqual(result['period']['emitted_intervals'], 1)

    def test_formal_count_fails_unsupported_claim_despite_95_percent_numeric_rates(self):
        source, reports = fixture(11)
        source['role'] = 'independent_acceptance'
        source['independent_untuned_person_ids'] = ['person-1', 'person-2', 'person-3']
        for i in [2, 3]:
            s, r = fixture(11, person=f'person-{i}', clip=f'clip-{i}')
            source['clips'].extend(s['clips']); reports['clips'].extend(r['clips'])
        next(t for t in reports['clips'][0]['report']['trace']
             if t['seconds'] == .5)['reason'] = 'missing_required_joint'
        result = e.evaluate(source, reports)
        self.assertEqual(result['count']['reference_cycles'], 33)
        self.assertGreaterEqual(result['count']['recall'], .95)
        self.assertGreaterEqual(result['count']['precision'], .95)
        self.assertEqual(result['count']['unknown'], 1)
        self.assertEqual(result['count']['acceptance'], 'failed')

    def test_missing_source_clock_and_unlocated_reset_are_not_continuity(self):
        for mode in ['clock', 'reset']:
            source, reports = fixture(2)
            if mode == 'clock':
                source['clips'][0].pop('frame_pts')
            else:
                reports['clips'][0]['report']['resetCounts'] = {'time_gap': 1}
            self.assertEqual(e.evaluate(source, reports)['period']['emitted_intervals'], 0)

    def test_duplicates_and_overlapping_reference_ownership_do_not_pass(self):
        source, reports = fixture(2)
        report = reports['clips'][0]['report']
        report['events'].insert(1, copy.deepcopy(report['events'][0])); report['count'] = 3
        result = e.evaluate(source, reports)
        self.assertEqual(result['count']['unknown'], 2)
        self.assertEqual(result['count']['TP'], 1)
        self.assertEqual(result['period']['emitted_intervals'], 0)
        source, reports = fixture(1)
        duplicate = copy.deepcopy(source['clips'][0]['cycles'][0]); duplicate['id'] = 'ambiguous-cycle'
        source['clips'][0]['cycles'].append(duplicate)
        result = e.evaluate(source, reports)
        self.assertEqual(result['count']['unknown'], 1)
        self.assertEqual(result['count']['TP'], 0)
        self.assertEqual(result['count']['FN'], 2)

    def test_spanning_event_is_fp_and_extra_event_blocks_neighboring_period(self):
        source, reports = fixture(2)
        report = reports['clips'][0]['report']
        report['events'] = [{'startedAtSeconds': .2, 'lowEndpointCandidateSeconds': .9,
                             'completedAtSeconds': 5.1}]; report['count'] = 1
        result = e.evaluate(source, reports)
        self.assertEqual((result['count']['TP'], result['count']['FP']), (0, 1))
        source, reports = fixture(2)
        report = reports['clips'][0]['report']
        report['events'].insert(1, {'startedAtSeconds': 2.2, 'lowEndpointCandidateSeconds': 2.4,
                                    'completedAtSeconds': 2.8}); report['count'] = 3
        result = e.evaluate(source, reports)
        self.assertEqual(result['count']['FP'], 1)
        self.assertEqual(result['period']['emitted_intervals'], 0)

    def test_wide_brackets_are_precision_unknown_not_zero_error(self):
        source, reports = fixture(2)
        source['clips'][0]['cycles'][0]['R'] = [1900, 2200]
        result = e.evaluate(source, reports)
        self.assertEqual(result['count']['TP'], 2)
        self.assertEqual(result['period']['emitted_intervals'], 0)
        self.assertEqual(result['period']['declared_intervals'], 1)
        self.assertIn('reference_precision_unknown', result['clips'][0]['intervals'][0]['reasons'])
        self.assertIsNone(result['period']['median_upper_abs_error_seconds'])

    def test_true_cycle_bracket_uncertainty_uses_upper_error_not_midpoint(self):
        source, reports = fixture(2)
        source['clips'][0]['cycles'][0]['R'] = [1900, 2100]
        source['clips'][0]['cycles'][1]['R'] = [4900, 5100]
        reports['clips'][0]['report']['events'][1]['completedAtSeconds'] = 5.2
        result = e.evaluate(source, reports)
        interval = result['clips'][0]['intervals'][0]
        self.assertEqual(interval['reference_seconds'], [2.8, 3.2])
        self.assertEqual(interval['abs_error_lower_seconds'], 0)
        self.assertAlmostEqual(interval['abs_error_upper_seconds'], .3)
        self.assertAlmostEqual(result['period']['median_upper_abs_error_seconds'], .3)

    def test_thirty_cycles_across_three_people_do_not_supply_thirty_periods(self):
        source, reports = fixture(10)
        source['role'] = 'independent_acceptance'
        source['independent_untuned_person_ids'] = ['person-1', 'person-2', 'person-3']
        for i in [2, 3]:
            s, r = fixture(10, person=f'person-{i}', clip=f'clip-{i}')
            source['clips'].extend(s['clips']); reports['clips'].extend(r['clips'])
        result = e.evaluate(source, reports)
        self.assertEqual(result['count']['acceptance'], 'passed_declared_independent_cohort')
        self.assertEqual(result['period']['declared_intervals'], 27)
        self.assertEqual(result['period']['acceptance'], 'development_only')
        for clip in source['clips']:
            self.assertEqual(len(clip['cycles']), 10)

    def test_sufficient_declared_cohort_can_pass_period_but_never_endpoint_claim(self):
        source, reports = fixture(11)
        source['role'] = 'independent_acceptance'
        source['independent_untuned_person_ids'] = ['person-1', 'person-2', 'person-3']
        for i in [2, 3]:
            s, r = fixture(11, person=f'person-{i}', clip=f'clip-{i}')
            source['clips'].extend(s['clips']); reports['clips'].extend(r['clips'])
        result = e.evaluate(source, reports)
        self.assertEqual(result['period']['reference_qualified_intervals'], 30)
        self.assertEqual(result['period']['acceptance'], 'passed_declared_independent_cohort')
        self.assertFalse(result['exact_endpoint_accuracy_claim'])

    def test_qualified_reference_with_model_failure_is_failed_not_sample_insufficient(self):
        source, reports = fixture(11)
        source['role'] = 'independent_acceptance'
        source['independent_untuned_person_ids'] = ['person-1', 'person-2', 'person-3']
        for i in [2, 3]:
            s, r = fixture(11, person=f'person-{i}', clip=f'clip-{i}')
            source['clips'].extend(s['clips']); reports['clips'].extend(r['clips'])
        failed = reports['clips'][2]['report']
        failed['events'] = []; failed['count'] = 0
        result = e.evaluate(source, reports)
        self.assertEqual(result['period']['reference_qualified_intervals'], 30)
        self.assertEqual(result['period']['declared_intervals'], 30)
        self.assertEqual(result['period']['emitted_intervals'], 20)
        self.assertEqual(result['period']['acceptance'], 'failed')

    def test_alias_clips_cannot_inflate_formal_count_or_period_sample(self):
        source, reports = fixture()
        source['role'] = 'independent_acceptance'
        source['independent_untuned_person_ids'] = ['person-1', 'person-2', 'person-3']
        for i in [2, 3]:
            s, r = fixture(person=f'person-{i}', clip=f'clip-{i}')
            source['clips'].extend(s['clips']); reports['clips'].extend(r['clips'])
        for clip, report in list(zip(source['clips'], reports['clips'])):
            for i in range(4):
                alias, wrapped = copy.deepcopy(clip), copy.deepcopy(report)
                alias['id'] = wrapped['id'] = f"{clip['id']}-alias-{i}"
                source['clips'].append(alias); reports['clips'].append(wrapped)
        # Relabeling the same 9 cycles otherwise fabricates 45 cycles / 30 periods.
        with self.assertRaisesRegex(ValueError, 'overlapping_source_declarations'):
            e.evaluate(source, reports)

    def test_same_source_disjoint_windows_allow_reuse_with_different_time_base(self):
        source, reports = fixture(2)
        clip, wrapped = copy.deepcopy(source['clips'][0]), copy.deepcopy(reports['clips'][0])
        clip['id'] = wrapped['id'] = 'later-window'
        clip['time_base'] = [1, 2000]
        for cy in clip['cycles']:
            for key in ['S', 'B', 'R', 'ownership']:
                cy[key] = [2*(p+6000) for p in cy[key]]
        clip['frame_pts'] = [2*(p+6000) for p in clip['frame_pts']]
        for event in wrapped['report']['events']:
            for key in ['startedAtSeconds', 'lowEndpointCandidateSeconds', 'completedAtSeconds']:
                event[key] += 6
        for row in wrapped['report']['trace']: row['seconds'] += 6
        source['clips'].append(clip); reports['clips'].append(wrapped)
        result = e.evaluate(source, reports)
        self.assertEqual(result['count']['TP'], 4)
        self.assertEqual(result['period']['emitted_intervals'], 2)
        # Same source ticks expressed at a different scale cannot hide overlap.
        for cy in clip['cycles']:
            for key in ['S', 'B', 'R', 'ownership']:
                cy[key] = [p-12000 for p in cy[key]]
        clip['frame_pts'] = [p-12000 for p in clip['frame_pts']]
        for event in wrapped['report']['events']:
            for key in ['startedAtSeconds', 'lowEndpointCandidateSeconds', 'completedAtSeconds']:
                event[key] -= 6
        for row in wrapped['report']['trace']: row['seconds'] -= 6
        with self.assertRaisesRegex(ValueError, 'overlapping_source_declarations'):
            e.evaluate(source, reports)

    def test_SBR_endpoints_must_be_on_frozen_clock_but_ownership_need_not(self):
        for key in ['S', 'B', 'R']:
            with self.subTest(endpoint=key):
                source, reports = fixture(2)
                source['clips'][0]['cycles'][0][key][1] += 1
                with self.assertRaisesRegex(ValueError, 'source_endpoint_off_clock'):
                    e.evaluate(source, reports)
        source, reports = fixture(2)
        self.assertNotIn(source['clips'][0]['cycles'][0]['ownership'][1], source['clips'][0]['frame_pts'])
        self.assertEqual(e.evaluate(source, reports)['count']['TP'], 2)

    def test_identity_nonadjacency_and_bad_pts_fail_closed(self):
        for mode in ['side', 'hash', 'interval', 'time', 'clock']:
            with self.subTest(mode=mode):
                source, reports = fixture()
                if mode == 'side': reports['clips'][0]['side'] = 'left'
                elif mode == 'hash': reports['clips'][0]['source_sha256'] = 'b'*64
                elif mode == 'interval': source['clips'][0]['intervals'][0]['to'] = 'cycle-3'
                elif mode == 'time': reports['clips'][0]['report']['events'][0]['completedAtSeconds'] = float('nan')
                else: source['clips'][0]['frame_pts'][0] = True
                with self.assertRaises(ValueError): e.evaluate(source, reports)

    def test_cli_exclusive_output_input_integrity_and_structured_errors(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source, reports = fixture(2)
            ref = root/'reference.json'; rep = root/'reports.json'; out = root/'evaluation.json'
            ref.write_text(json.dumps(source)); rep.write_text(json.dumps(reports))
            before = (ref.read_bytes(), rep.read_bytes())
            argv = [sys.executable, str(SCRIPT), '--reference', str(ref), '--reports', str(rep), '--output', str(out)]
            first = subprocess.run(argv, capture_output=True, text=True, timeout=10)
            self.assertEqual(first.returncode, 0, first.stderr)
            result = json.loads(out.read_text())
            self.assertEqual(result['artifacts']['reference']['sha256'], __import__('hashlib').sha256(before[0]).hexdigest())
            saved = out.read_bytes()
            second = subprocess.run(argv, capture_output=True, text=True, timeout=10)
            self.assertEqual(second.returncode, 2)
            self.assertEqual(json.loads(second.stderr)['error']['code'], 'output_exists')
            self.assertEqual(out.read_bytes(), saved)
            self.assertEqual((ref.read_bytes(), rep.read_bytes()), before)
            rep.write_text('{broken')
            argv[-1] = str(root/'bad.json')
            failed = subprocess.run(argv, capture_output=True, text=True, timeout=10)
            self.assertEqual(failed.returncode, 2)
            self.assertEqual(json.loads(failed.stderr)['error']['stage'], 'reports')
            self.assertFalse((root/'bad.json').exists())


if __name__ == '__main__':
    unittest.main()
