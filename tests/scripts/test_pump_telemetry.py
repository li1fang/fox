"""Synthetic wire layouts derived from the documented protocol; no device records."""
import importlib.util
from pathlib import Path
import unittest
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/"scripts"))

spec=importlib.util.spec_from_file_location('pump_telemetry',Path(__file__).resolve().parents[2]/'scripts/pump_telemetry.py')
pump=importlib.util.module_from_spec(spec)
spec.loader.exec_module(pump)


def wire(tag, payload):
    data=bytes([0x53,len(payload)+4,tag,*payload])
    return data+bytes([(-sum(data))&255])


class PumpTelemetryTests(unittest.TestCase):
    def test_device_heartbeat_is_unverified_vendor_fields_not_force(self):
        result=pump.decode(wire(2,[1,30,40,50,90,2,9]))
        self.assertEqual(result['state'],'decoded')
        self.assertEqual(result['fields']['work_state_raw'],1)
        self.assertEqual(result['fields']['motor_temperature_c_upstream'],9)
        self.assertNotIn('force_n',result['fields'])
    def test_little_endian_and_zero_preserved_without_si_conversion(self):
        payload=[3,26,9,0x34,0x12,1,2,3,4,5,6,7,8,9,10,11,12]
        result=pump.decode(wire(3,payload))
        self.assertEqual(result['fields']['repetitions_raw'],0x1234)
        self.assertEqual(result['fields']['distance_raw'],0x030201)
        self.assertEqual(result['fields']['energy_raw'],0x060504)
        self.assertEqual(result['fields']['tension_time_raw'],0x0807)
        self.assertNotIn('position_m',result['fields'])
        self.assertEqual(pump.decode(wire(3,[0]*17))['fields']['cable_length_raw'],0)
    def test_bad_checksum_truncation_unknown_and_combined_are_quarantined(self):
        good=wire(3,[0]*17)
        for raw in [good[:-1],good[:-1]+bytes([(good[-1]+1)&255]),good+good,b'',wire(0x99,[1,2]),wire(1,[0,0])]:
            result=pump.decode(raw)
            self.assertNotEqual(result['state'],'decoded')
            self.assertEqual(result['fields'],{})
            self.assertEqual(bytes.fromhex(result['raw_hex']),raw)
    def test_connection_segments_keep_both_devices_and_reconnect_separate(self):
        a=pump.Connection('capture-A','pump-A','segment-1','ipad-host-1')
        b=pump.Connection('capture-A','pump-B','segment-2','ipad-host-1')
        one=a.receive(wire(3,[0]*17),'1000'); two=b.receive(wire(3,[0]*17),'1001')
        self.assertEqual(one['notification_seq'],0);self.assertEqual(two['notification_seq'],0)
        self.assertNotEqual(one['device_alias'],two['device_alias'])
        self.assertIsNone(one['device_tick'])
        a.disconnect('1002','link_lost')
        with self.assertRaises(ValueError):a.receive(wire(3,[0]*17),'1003')
        c=pump.Connection('capture-A','pump-A','segment-3','ipad-host-1')
        self.assertNotEqual(c.receive(wire(3,[0]*17),'1004')['connection_segment_id'],one['connection_segment_id'])
    def test_host_time_is_monotonic_and_has_no_device_clock_claim(self):
        a=pump.Connection('capture-A','pump-A','segment-1','ipad-host-1')
        a.receive(wire(2,[1,30,40,50,90,2,9]),'9007199254740993')
        with self.assertRaises(ValueError): a.receive(wire(3,[0]*17),'9007199254740992')
        self.assertEqual(a.receive(wire(3,[0]*17),'9007199254740994')['notification_seq'],1)
    def test_transport_exposes_only_notify_characteristic(self):
        self.assertEqual(pump.NOTIFY_CHARACTERISTIC,'0000ffe1-0000-1000-8000-00805f9b34fb')
        self.assertFalse(hasattr(pump,'encode_command'))
        self.assertFalse(hasattr(pump,'set_resistance'))

if __name__=='__main__':unittest.main()
