/// Bounded S-H1 development probe. These values are not ordinary App admission.
/// Geometry, dwell, duration, binding and loss semantics remain owned by the counter.
public enum SquatJointConfidenceFloor: Double, Codable, CaseIterable {
    case baseline = 0.5
    case subjectGate = 0.35
    case lowerProbe = 0.25
}
