# Schema Examples

## Meal entry

```json
{
  "id": "entry_001",
  "type": "meal",
  "occurred_at": "2026-06-25T12:30:00+07:00",
  "timezone": "Asia/Bangkok",
  "title": "Lunch",
  "status": "extracted",
  "evidence": [
    {
      "id": "ev_001",
      "kind": "image",
      "uri": "object://fox/evidence/ev_001.jpg",
      "mime_type": "image/jpeg",
      "created_at": "2026-06-25T12:31:00+07:00"
    }
  ],
  "extracted_json": {
    "meal_name": "Lunch",
    "items": [
      {
        "name": "rice bowl",
        "portion": "one bowl",
        "estimated_calories": 520,
        "confidence": 0.62
      }
    ],
    "total_estimated_calories": 520
  },
  "extraction_confidence": 0.62,
  "created_at": "2026-06-25T12:31:00+07:00",
  "updated_at": "2026-06-25T12:31:00+07:00"
}
```

## Medical payload

```json
{
  "source_type": "prescription",
  "medicines": [
    {
      "name": "example medicine",
      "dosage": "500 mg",
      "frequency": "twice daily",
      "duration": "5 days",
      "instructions": "after meals",
      "warnings": "confirm with doctor before combining with other medicine"
    }
  ],
  "doctor_notes": "Follow up if symptoms do not improve."
}
```

## Workout entry

```json
{
  "id": "entry_workout_001",
  "type": "workout",
  "occurred_at": "2026-06-25T18:30:00+07:00",
  "timezone": "Asia/Bangkok",
  "title": "家庭健身房推举训练",
  "status": "confirmed",
  "evidence": [
    {
      "id": "ev_text_001",
      "kind": "text",
      "uri": "object://fox/evidence/ev_text_001.txt",
      "mime_type": "text/plain",
      "created_at": "2026-06-25T19:10:00+07:00"
    }
  ],
  "confirmed_json": {
    "workout_name": "家庭健身房推举训练",
    "location": "home_gym",
    "focus": "shoulders and push",
    "started_at": "2026-06-25T18:30:00+07:00",
    "ended_at": "2026-06-25T19:10:00+07:00",
    "duration_seconds": 2400,
    "status": "confirmed",
    "plan": {
      "estimated_duration_minutes": 40,
      "warmup": "5 minutes light cardio",
      "cooldown": "shoulder and chest stretch",
      "safety_notes": "If shoulder pain appears, stop pressing movements.",
      "exercises": [
        {
          "exercise_id": "dumbbell_shoulder_press",
          "name": "Dumbbell Shoulder Press",
          "category": "push",
          "target_sets": [
            {
              "set_index": 1,
              "target_reps": 10,
              "target_weight": 7.5,
              "weight_unit": "kg",
              "rest_seconds": 90
            },
            {
              "set_index": 2,
              "target_reps": 10,
              "target_weight": 7.5,
              "weight_unit": "kg",
              "rest_seconds": 90
            }
          ],
          "rest_seconds": 90,
          "notes": "Conservative starting point."
        }
      ]
    },
    "actual": {
      "exercises": [
        {
          "exercise_id": "dumbbell_shoulder_press",
          "name": "Dumbbell Shoulder Press",
          "category": "push",
          "completed_sets": [
            {
              "set_index": 1,
              "planned_set_index": 1,
              "status": "completed",
              "reps": 10,
              "weight": 7.5,
              "weight_unit": "kg",
              "counting_method": "manual"
            },
            {
              "set_index": 2,
              "planned_set_index": 2,
              "status": "partial",
              "reps": 7,
              "weight": 7.5,
              "weight_unit": "kg",
              "notes": "not followed",
              "counting_method": "manual"
            }
          ]
        }
      ],
      "completion_notes": "Second set missed target, later push work should reduce intensity."
    },
    "feedback_events": [
      {
        "id": "fb_001",
        "at": "2026-06-25T18:45:00+07:00",
        "state": "feedback",
        "kind": "not_followed",
        "exercise_name": "Dumbbell Shoulder Press",
        "set_index": 2,
        "message": "Only completed 7 reps."
      }
    ],
    "timer_events": [
      {
        "id": "timer_001",
        "at": "2026-06-25T18:40:00+07:00",
        "kind": "rest_timer_started",
        "duration_seconds": 90,
        "target": "Dumbbell Shoulder Press set 1"
      }
    ],
    "adjustments": [
      {
        "id": "adj_001",
        "at": "2026-06-25T18:46:00+07:00",
        "reason": "not_followed",
        "decided_by": "rules",
        "target": "next push exercise",
        "before": { "target_reps": 10 },
        "after": { "target_reps": 8 }
      }
    ],
    "coach_summary": "今天完成了肩推训练，但第二组没有跟上，后续推举动作应降低目标次数。",
    "user_confirmation_status": "confirmed"
  },
  "created_at": "2026-06-25T18:30:00+07:00",
  "updated_at": "2026-06-25T19:12:00+07:00"
}
```
