import type { DailyCheckIn, ExerciseBlock, TempoPhase, WorkoutPlan, WorkoutSession } from "./types.js";

const defaultTempo: TempoPhase[] = [
  { phase: "lift", seconds: 2, visual: "expand" },
  { phase: "peak", seconds: 1, visual: "vibrate" },
  { phase: "lower", seconds: 3, visual: "shrink" }
];

const holdTempo: TempoPhase[] = [{ phase: "hold", seconds: 1, visual: "hold" }];

export function createInitialSession(now = new Date().toISOString()): WorkoutSession {
  return {
    id: `session_${Date.now()}`,
    status: "idle",
    currentExerciseIndex: 0,
    currentSetIndex: 0,
    feedbackEvents: [],
    timerEvents: [],
    adjustments: [],
    coachMessages: [],
    aiAudits: [],
    createdAt: now,
    updatedAt: now
  };
}

export function createConservativePlan(checkIn: DailyCheckIn): WorkoutPlan {
  const fatiguePenalty = checkIn.sleep === "poor" || checkIn.fatigue === "high" || checkIn.stress === "high";
  const shortSession = checkIn.availableMinutes < 35;
  const shoulderCaution = checkIn.painAreas.some((area) => ["shoulder", "肩", "肩膀"].includes(area.toLowerCase()));

  const shoulderPressReps = fatiguePenalty || shoulderCaution ? 8 : 10;
  const lateralRaiseReps = fatiguePenalty ? 10 : 12;
  const plankSeconds = fatiguePenalty ? 35 : 45;

  const exercises: ExerciseBlock[] = [
    {
      exerciseId: "dumbbell_shoulder_press",
      name: "Dumbbell Shoulder Press",
      category: "push",
      restSeconds: fatiguePenalty ? 120 : 90,
      tempo: defaultTempo,
      notes: shoulderCaution ? "Shoulder caution: stop on pain." : "Conservative shoulder press baseline.",
      targetSets: [
        {
          setIndex: 1,
          targetReps: shoulderPressReps,
          targetWeight: 7.5,
          weightUnit: "kg",
          restSeconds: fatiguePenalty ? 120 : 90
        },
        {
          setIndex: 2,
          targetReps: shoulderPressReps,
          targetWeight: 7.5,
          weightUnit: "kg",
          restSeconds: fatiguePenalty ? 120 : 90
        }
      ],
      completedSets: []
    },
    {
      exerciseId: "lateral_raise",
      name: "Lateral Raise",
      category: "push",
      restSeconds: 90,
      tempo: defaultTempo,
      notes: "Keep it strict; avoid swinging.",
      targetSets: [
        { setIndex: 1, targetReps: lateralRaiseReps, targetWeight: 2.5, weightUnit: "kg", restSeconds: 90 },
        { setIndex: 2, targetReps: lateralRaiseReps, targetWeight: 2.5, weightUnit: "kg", restSeconds: 90 }
      ],
      completedSets: []
    },
    {
      exerciseId: "plank",
      name: "Plank",
      category: "core",
      restSeconds: 75,
      tempo: holdTempo,
      notes: "Timer-based hold; stop if lower back hurts.",
      targetSets: [
        { setIndex: 1, targetDurationSeconds: plankSeconds, weightUnit: "bodyweight", restSeconds: 75 },
        { setIndex: 2, targetDurationSeconds: plankSeconds, weightUnit: "bodyweight", restSeconds: 75 }
      ],
      completedSets: []
    }
  ];

  return {
    focus: shoulderCaution ? "low-risk shoulders and core" : "shoulders, push, and core",
    estimatedDurationMinutes: shortSession ? Math.max(20, checkIn.availableMinutes) : 40,
    warmup: "5 minutes light cardio plus shoulder circles.",
    cooldown: "Shoulder, chest, and light core stretch. Stretching is not counted in main progress.",
    safetyNotes: "Pain stops the current movement. Do not chase missed reps.",
    exercises: shortSession ? exercises.slice(0, 2) : exercises
  };
}
