package webhooks

import (
	"context"
	"testing"

	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/utils/ptr"
	v1 "sigs.k8s.io/lws/api/leaderworkerset/v1"
	"sigs.k8s.io/lws/test/wrappers"
)

func TestPartitionValidation(t *testing.T) {
	tests := []struct {
		name        string
		lws         *v1.LeaderWorkerSet
		expectError bool
		errorMsg    string
	}{
		{
			name: "Valid partition equal to 0",
			lws: wrappers.BuildBasicLeaderWorkerSet("test", "default").
				Replica(6).
				Size(2).
				RolloutStrategy(v1.RolloutStrategy{
					Type: v1.RollingUpdateStrategyType,
					RollingUpdateConfiguration: &v1.RollingUpdateConfiguration{
						Partition:      ptr.To[int32](0),
						MaxUnavailable: intstr.FromInt32(1),
						MaxSurge:       intstr.FromInt32(1),
					},
				}).
				WorkerTemplateSpec(wrappers.MakeWorkerPodSpec()).
				Obj(),
			expectError: false,
		},
		{
			name: "Valid partition less than replicas",
			lws: wrappers.BuildBasicLeaderWorkerSet("test", "default").
				Replica(6).
				Size(2).
				RolloutStrategy(v1.RolloutStrategy{
					Type: v1.RollingUpdateStrategyType,
					RollingUpdateConfiguration: &v1.RollingUpdateConfiguration{
						Partition:      ptr.To[int32](3),
						MaxUnavailable: intstr.FromInt32(1),
						MaxSurge:       intstr.FromInt32(1),
					},
				}).
				WorkerTemplateSpec(wrappers.MakeWorkerPodSpec()).
				Obj(),
			expectError: false,
		},
		{
			name: "Valid partition equal to replicas",
			lws: wrappers.BuildBasicLeaderWorkerSet("test", "default").
				Replica(6).
				Size(2).
				RolloutStrategy(v1.RolloutStrategy{
					Type: v1.RollingUpdateStrategyType,
					RollingUpdateConfiguration: &v1.RollingUpdateConfiguration{
						Partition:      ptr.To[int32](6),
						MaxUnavailable: intstr.FromInt32(1),
						MaxSurge:       intstr.FromInt32(1),
					},
				}).
				WorkerTemplateSpec(wrappers.MakeWorkerPodSpec()).
				Obj(),
			expectError: false,
		},
		{
			name: "Invalid partition greater than replicas - now allowed with warning",
			lws: wrappers.BuildBasicLeaderWorkerSet("test", "default").
				Replica(6).
				Size(2).
				RolloutStrategy(v1.RolloutStrategy{
					Type: v1.RollingUpdateStrategyType,
					RollingUpdateConfiguration: &v1.RollingUpdateConfiguration{
						Partition:      ptr.To[int32](9),
						MaxUnavailable: intstr.FromInt32(1),
						MaxSurge:       intstr.FromInt32(1),
					},
				}).
				WorkerTemplateSpec(wrappers.MakeWorkerPodSpec()).
				Obj(),
			expectError: false, // Changed: now allowed with warning
			errorMsg:    "",
		},
		{
			name: "Invalid negative partition",
			lws: wrappers.BuildBasicLeaderWorkerSet("test", "default").
				Replica(6).
				Size(2).
				RolloutStrategy(v1.RolloutStrategy{
					Type: v1.RollingUpdateStrategyType,
					RollingUpdateConfiguration: &v1.RollingUpdateConfiguration{
						Partition:      ptr.To[int32](-1),
						MaxUnavailable: intstr.FromInt32(1),
						MaxSurge:       intstr.FromInt32(1),
					},
				}).
				WorkerTemplateSpec(wrappers.MakeWorkerPodSpec()).
				Obj(),
			expectError: true,
			errorMsg:    "partition must be greater than or equal to 0",
		},
	}

	webhook := &LeaderWorkerSetWebhook{}
	
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := webhook.ValidateCreate(context.TODO(), tc.lws)
			
			if tc.expectError {
				if err == nil {
					t.Errorf("Expected error but got none")
				} else if tc.errorMsg != "" && !contains(err.Error(), tc.errorMsg) {
					t.Errorf("Expected error containing '%s', got '%s'", tc.errorMsg, err.Error())
				}
			} else {
				if err != nil {
					t.Errorf("Unexpected error: %v", err)
				}
			}
		})
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && (s[0:len(substr)] == substr || contains(s[1:], substr)))
}