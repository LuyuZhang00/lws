/*
Copyright 2025.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package schedulerprovider

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	volcanov1beta1 "volcano.sh/apis/pkg/apis/scheduling/v1beta1"

	leaderworkerset "sigs.k8s.io/lws/api/leaderworkerset/v1"
)

func TestVolcanoProvider_CreatePodGroupWithNetworkTopology(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)
	_ = leaderworkerset.AddToScheme(scheme)
	_ = volcanov1beta1.AddToScheme(scheme)

	tests := []struct {
		name                   string
		lws                    *leaderworkerset.LeaderWorkerSet
		leaderPod              *corev1.Pod
		expectedNetworkTopology *volcanov1beta1.NetworkTopologySpec
	}{
		{
			name: "Hard mode with tier 2",
			lws: &leaderworkerset.LeaderWorkerSet{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "test-lws-hard",
					Namespace: "default",
				},
				Spec: leaderworkerset.LeaderWorkerSetSpec{
					Replicas: ptr.To[int32](2),
					LeaderWorkerTemplate: leaderworkerset.LeaderWorkerTemplate{
						Size: ptr.To[int32](4),
					},
					NetworkTopology: &leaderworkerset.NetworkTopology{
						Mode:               "hard",
						HighestTierAllowed: 2,
					},
				},
			},
			leaderPod: &corev1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "test-lws-hard-0",
					Namespace: "default",
					Labels: map[string]string{
						leaderworkerset.SetNameLabelKey:    "test-lws-hard",
						leaderworkerset.GroupIndexLabelKey: "0",
						leaderworkerset.RevisionKey:        "rev1",
					},
					Annotations: map[string]string{
						volcanov1beta1.KubeGroupNameAnnotationKey: "test-lws-hard-0-rev1",
					},
				},
			},
			expectedNetworkTopology: &volcanov1beta1.NetworkTopologySpec{
				Mode:               volcanov1beta1.HardNetworkTopologyMode,
				HighestTierAllowed: ptr.To(2),
			},
		},
		{
			name: "Soft mode with tier 1",
			lws: &leaderworkerset.LeaderWorkerSet{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "test-lws-soft",
					Namespace: "default",
				},
				Spec: leaderworkerset.LeaderWorkerSetSpec{
					Replicas: ptr.To[int32](1),
					LeaderWorkerTemplate: leaderworkerset.LeaderWorkerTemplate{
						Size: ptr.To[int32](8),
					},
					NetworkTopology: &leaderworkerset.NetworkTopology{
						Mode:               "soft",
						HighestTierAllowed: 1,
					},
				},
			},
			leaderPod: &corev1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "test-lws-soft-0",
					Namespace: "default",
					Labels: map[string]string{
						leaderworkerset.SetNameLabelKey:    "test-lws-soft",
						leaderworkerset.GroupIndexLabelKey: "0",
						leaderworkerset.RevisionKey:        "rev2",
					},
					Annotations: map[string]string{
						volcanov1beta1.KubeGroupNameAnnotationKey: "test-lws-soft-0-rev2",
					},
				},
			},
			expectedNetworkTopology: &volcanov1beta1.NetworkTopologySpec{
				Mode:               volcanov1beta1.SoftNetworkTopologyMode,
				HighestTierAllowed: ptr.To(1),
			},
		},
		{
			name: "No network topology",
			lws: &leaderworkerset.LeaderWorkerSet{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "test-lws-no-topology",
					Namespace: "default",
				},
				Spec: leaderworkerset.LeaderWorkerSetSpec{
					Replicas: ptr.To[int32](1),
					LeaderWorkerTemplate: leaderworkerset.LeaderWorkerTemplate{
						Size: ptr.To[int32](2),
					},
				},
			},
			leaderPod: &corev1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "test-lws-no-topology-0",
					Namespace: "default",
					Labels: map[string]string{
						leaderworkerset.SetNameLabelKey:    "test-lws-no-topology",
						leaderworkerset.GroupIndexLabelKey: "0",
						leaderworkerset.RevisionKey:        "rev3",
					},
					Annotations: map[string]string{
						volcanov1beta1.KubeGroupNameAnnotationKey: "test-lws-no-topology-0-rev3",
					},
				},
			},
			expectedNetworkTopology: nil,
		},
		{
			name: "Default to hard mode when mode is empty",
			lws: &leaderworkerset.LeaderWorkerSet{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "test-lws-default",
					Namespace: "default",
				},
				Spec: leaderworkerset.LeaderWorkerSetSpec{
					Replicas: ptr.To[int32](1),
					LeaderWorkerTemplate: leaderworkerset.LeaderWorkerTemplate{
						Size: ptr.To[int32](3),
					},
					NetworkTopology: &leaderworkerset.NetworkTopology{
						Mode:               "", // Empty mode should default to hard
						HighestTierAllowed: 3,
					},
				},
			},
			leaderPod: &corev1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "test-lws-default-0",
					Namespace: "default",
					Labels: map[string]string{
						leaderworkerset.SetNameLabelKey:    "test-lws-default",
						leaderworkerset.GroupIndexLabelKey: "0",
						leaderworkerset.RevisionKey:        "rev4",
					},
					Annotations: map[string]string{
						volcanov1beta1.KubeGroupNameAnnotationKey: "test-lws-default-0-rev4",
					},
				},
			},
			expectedNetworkTopology: &volcanov1beta1.NetworkTopologySpec{
				Mode:               volcanov1beta1.HardNetworkTopologyMode,
				HighestTierAllowed: ptr.To(3),
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx := context.Background()

			// Create fake client
			fakeClient := fake.NewClientBuilder().
				WithScheme(scheme).
				WithObjects(tt.lws, tt.leaderPod).
				Build()

			// Create VolcanoProvider
			provider := NewVolcanoProvider(fakeClient)

			// Call CreatePodGroupIfNotExists
			err := provider.CreatePodGroupIfNotExists(ctx, tt.lws, tt.leaderPod)
			assert.NoError(t, err)

			// Get the created PodGroup
			var pg volcanov1beta1.PodGroup
			pgName := tt.leaderPod.Annotations[volcanov1beta1.KubeGroupNameAnnotationKey]
			err = fakeClient.Get(ctx, client.ObjectKey{
				Name:      pgName,
				Namespace: tt.lws.Namespace,
			}, &pg)
			assert.NoError(t, err)

			// Verify NetworkTopology
			if tt.expectedNetworkTopology == nil {
				assert.Nil(t, pg.Spec.NetworkTopology)
			} else {
				assert.NotNil(t, pg.Spec.NetworkTopology)
				assert.Equal(t, tt.expectedNetworkTopology.Mode, pg.Spec.NetworkTopology.Mode)
				if tt.expectedNetworkTopology.HighestTierAllowed != nil {
					assert.NotNil(t, pg.Spec.NetworkTopology.HighestTierAllowed)
					assert.Equal(t, *tt.expectedNetworkTopology.HighestTierAllowed, *pg.Spec.NetworkTopology.HighestTierAllowed)
				}
			}

			// Verify other PodGroup fields
			assert.Equal(t, tt.lws.Name, pg.Labels[leaderworkerset.SetNameLabelKey])
			assert.Equal(t, tt.leaderPod.Labels[leaderworkerset.GroupIndexLabelKey], pg.Labels[leaderworkerset.GroupIndexLabelKey])
			assert.Equal(t, *tt.lws.Spec.LeaderWorkerTemplate.Size, pg.Spec.MinMember)
		})
	}
}

func TestVolcanoProvider_UpdateExistingPodGroup(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)
	_ = leaderworkerset.AddToScheme(scheme)
	_ = volcanov1beta1.AddToScheme(scheme)

	ctx := context.Background()

	// Create LWS with network topology
	lws := &leaderworkerset.LeaderWorkerSet{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-lws",
			Namespace: "default",
		},
		Spec: leaderworkerset.LeaderWorkerSetSpec{
			Replicas: ptr.To[int32](1),
			LeaderWorkerTemplate: leaderworkerset.LeaderWorkerTemplate{
				Size: ptr.To[int32](4),
			},
			NetworkTopology: &leaderworkerset.NetworkTopology{
				Mode:               "hard",
				HighestTierAllowed: 2,
			},
		},
	}

	leaderPod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-lws-0",
			Namespace: "default",
			Labels: map[string]string{
				leaderworkerset.SetNameLabelKey:    "test-lws",
				leaderworkerset.GroupIndexLabelKey: "0",
				leaderworkerset.RevisionKey:        "rev1",
			},
			Annotations: map[string]string{
				volcanov1beta1.KubeGroupNameAnnotationKey: "test-lws-0-rev1",
			},
		},
	}

	// Create existing PodGroup without network topology
	existingPG := &volcanov1beta1.PodGroup{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-lws-0-rev1",
			Namespace: "default",
		},
		Spec: volcanov1beta1.PodGroupSpec{
			MinMember: 4,
		},
	}

	// Create fake client with existing PodGroup
	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(lws, leaderPod, existingPG).
		Build()

	// Create VolcanoProvider
	provider := NewVolcanoProvider(fakeClient)

	// Call CreatePodGroupIfNotExists (should not create new PG, but use existing)
	err := provider.CreatePodGroupIfNotExists(ctx, lws, leaderPod)
	assert.NoError(t, err)

	// Get the PodGroup
	var pg volcanov1beta1.PodGroup
	err = fakeClient.Get(ctx, client.ObjectKey{
		Name:      "test-lws-0-rev1",
		Namespace: "default",
	}, &pg)
	assert.NoError(t, err)

	// Verify that the existing PodGroup is not updated (NetworkTopology remains nil)
	// This is expected behavior as CreatePodGroupIfNotExists doesn't update existing PodGroups
	assert.Nil(t, pg.Spec.NetworkTopology)
}