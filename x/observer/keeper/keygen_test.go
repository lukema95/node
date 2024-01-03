package keeper

import (
	"testing"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/stretchr/testify/assert"

	"github.com/zeta-chain/zetacore/x/observer/types"
)

// Keeper Tests
func createTestKeygen(keeper *Keeper, ctx sdk.Context) types.Keygen {
	item := types.Keygen{
		BlockNumber: 10,
	}
	keeper.SetKeygen(ctx, item)
	return item
}

func TestKeygenGet(t *testing.T) {
	keeper, ctx := SetupKeeper(t)
	item := createTestKeygen(keeper, ctx)
	rst, found := keeper.GetKeygen(ctx)
	assert.True(t, found)
	assert.Equal(t, item, rst)
}
func TestKeygenRemove(t *testing.T) {
	keeper, ctx := SetupKeeper(t)
	createTestKeygen(keeper, ctx)
	keeper.RemoveKeygen(ctx)
	_, found := keeper.GetKeygen(ctx)
	assert.False(t, found)
}
