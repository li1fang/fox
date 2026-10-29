"""Pure, conservative PUMP inbound telemetry profile. No BLE or control encoder.

Byte layout reference: engineering handoff 2026-10-29, upstream revision
51dd3e0620993ddf095a8491d789326b62ed61f9. Independently implemented; no
upstream source or real recordings bundled. Units/calibration remain unverified.
"""
from lab_capture import decimal, identifier, require, text

SERVICE = '0000ffe0-0000-1000-8000-00805f9b34fb'
NOTIFY_CHARACTERISTIC = '0000ffe1-0000-1000-8000-00805f9b34fb'
PROFILE = 'fox.pump_inbound_observed.v1'


def decode(raw):
    require(isinstance(raw, bytes) and len(raw) <= 65536, 'Invalid notification bytes')
    result = dict(profile=PROFILE, state='quarantined', reason=None, raw_hex=raw.hex(),
                  checksum_pass=None, kind='unknown', fields={})
    if len(raw) > 512:
        result['reason'] = 'oversize_notification'; return result
    if len(raw) < 4:
        result['reason'] = 'short_frame'; return result
    result['checksum_pass'] = sum(raw) & 255 == 0
    if raw[0] != 0x53:
        result['reason'] = 'unexpected_header'; return result
    if raw[1] != len(raw):
        result['reason'] = 'length_mismatch'; return result
    if not result['checksum_pass']:
        result['reason'] = 'checksum_mismatch'; return result
    tag = raw[2]
    if tag not in (2, 3):
        result.update(state='unsupported',reason='unsupported_type'); return result
    if len(raw) != (11 if tag == 2 else 21):
        result['reason'] = 'unsupported_profile_length'; return result
    if tag == 2:
        result['kind'] = 'device_heartbeat'
        values = dict(work_state_raw=raw[3], motor_temperature_c_upstream=raw[4]-21,
                      board_temperature_c_upstream=raw[5]-21,battery_temperature_c_upstream=raw[6]-21,
                      battery_percent_raw=raw[7],firmware_main_raw=raw[8],firmware_sub_raw=raw[9])
    else:
        result['kind'] = 'sports_heartbeat'
        values = dict(unknown_3_raw=raw[3],cable_length_raw=raw[4],speed_raw=raw[5],
                      repetitions_raw=int.from_bytes(raw[6:8],'little'),distance_raw=int.from_bytes(raw[8:11],'little'),
                      energy_raw=int.from_bytes(raw[11:14],'little'),tension_time_raw=int.from_bytes(raw[14:16],'little'),
                      power_raw=raw[16],recovery_raw=int.from_bytes(raw[17:20],'little'))
    result.update(state='decoded',reason=None,fields=values)
    return result


class Connection:
    """One immutable device/connection identity; reconnect requires a new object/ID."""
    def __init__(self,capture_id,device_alias,connection_segment_id,host_clock_id):
        for value in (capture_id,device_alias,connection_segment_id,host_clock_id): identifier(value)
        self.capture_id=capture_id; self.device_alias=device_alias
        self.connection_segment_id=connection_segment_id; self.host_clock_id=host_clock_id
        self.seq=0; self.last_host=-1; self.closed=False

    def receive(self,raw,host_received_ns):
        require(not self.closed, 'Connection segment closed')
        host=decimal(host_received_ns); require(host>=self.last_host,'Host clock decreased')
        decoded=decode(raw)
        event=dict(schema='fox.lab_pump_notification.v1',capture_id=self.capture_id,device_alias=self.device_alias,
                   connection_segment_id=self.connection_segment_id,host_clock_id=self.host_clock_id,
                   notification_seq=self.seq,host_received_ns=host_received_ns,device_tick=None,decoded=decoded)
        self.seq+=1; self.last_host=host
        return event

    def disconnect(self,host_received_ns,reason):
        require(not self.closed,'Connection segment closed')
        host=decimal(host_received_ns); require(host>=self.last_host,'Host clock decreased'); text(reason)
        self.closed=True; self.last_host=host
        return dict(schema='fox.lab_pump_connection.v1',capture_id=self.capture_id,device_alias=self.device_alias,
                    connection_segment_id=self.connection_segment_id,host_clock_id=self.host_clock_id,
                    host_received_ns=host_received_ns,state='disconnected',reason=reason)
