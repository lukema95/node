package observer_test

import (
	"context"
	"encoding/hex"
	"testing"

	"github.com/rs/zerolog"
	"github.com/stretchr/testify/require"
	"github.com/zeta-chain/node/pkg/chains"
	"github.com/zeta-chain/node/pkg/coin"
	"github.com/zeta-chain/node/pkg/constant"
	contracts "github.com/zeta-chain/node/pkg/contracts/solana"
	"github.com/zeta-chain/node/testutil/sample"
	"github.com/zeta-chain/node/zetaclient/chains/base"
	"github.com/zeta-chain/node/zetaclient/chains/solana/observer"
	"github.com/zeta-chain/node/zetaclient/config"
	"github.com/zeta-chain/node/zetaclient/db"
	"github.com/zeta-chain/node/zetaclient/keys"
	"github.com/zeta-chain/node/zetaclient/testutils"
	"github.com/zeta-chain/node/zetaclient/testutils/mocks"
	clienttypes "github.com/zeta-chain/node/zetaclient/types"
)

var (
	// the relative path to the testdata directory
	TestDataDir = "../../../"
)

func Test_FilterInboundEventAndVote(t *testing.T) {
	// load archived inbound vote tx result
	// https://explorer.solana.com/tx/24GzWsxYCFcwwJ2rzAsWwWC85aYKot6Rz3jWnBP1GvoAg5A9f1WinYyvyKseYM52q6i3EkotZdJuQomGGq5oxRYr?cluster=devnet
	txHash := "24GzWsxYCFcwwJ2rzAsWwWC85aYKot6Rz3jWnBP1GvoAg5A9f1WinYyvyKseYM52q6i3EkotZdJuQomGGq5oxRYr"
	chain := chains.SolanaDevnet
	txResult := testutils.LoadSolanaInboundTxResult(t, TestDataDir, chain.ChainId, txHash, false)

	database, err := db.NewFromSqliteInMemory(true)
	require.NoError(t, err)

	// create observer
	chainParams := sample.ChainParams(chain.ChainId)
	chainParams.GatewayAddress = GatewayAddressTest
	zetacoreClient := mocks.NewZetacoreClient(t)
	zetacoreClient.WithKeys(&keys.Keys{}).WithZetaChain().WithPostVoteInbound("", "")

	baseObserver, err := base.NewObserver(
		chain,
		*chainParams,
		zetacoreClient,
		nil,
		1000,
		nil,
		database,
		base.DefaultLogger(),
	)
	require.NoError(t, err)

	ob, err := observer.New(baseObserver, nil, chainParams.GatewayAddress)
	require.NoError(t, err)

	t.Run("should filter inbound events and vote", func(t *testing.T) {
		err := ob.FilterInboundEventsAndVote(context.TODO(), txResult)
		require.NoError(t, err)
	})
}

func Test_FilterInboundEvents(t *testing.T) {
	// load archived inbound deposit tx result
	// https://explorer.solana.com/tx/MS3MPLN7hkbyCZFwKqXcg8fmEvQMD74fN6Ps2LSWXJoRxPW5ehaxBorK9q1JFVbqnAvu9jXm6ertj7kT7HpYw1j?cluster=devnet
	txHash := "24GzWsxYCFcwwJ2rzAsWwWC85aYKot6Rz3jWnBP1GvoAg5A9f1WinYyvyKseYM52q6i3EkotZdJuQomGGq5oxRYr"
	chain := chains.SolanaDevnet
	txResult := testutils.LoadSolanaInboundTxResult(t, TestDataDir, chain.ChainId, txHash, false)

	// given gateway ID
	gatewayID, _, err := contracts.ParseGatewayWithPDA(testutils.OldSolanaGatewayAddressDevnet)
	require.NoError(t, err)

	// expected result
	sender := "HgTpiVRvjUPUcWLzdmCgdadu1GceJNgBWLoN9r66p8o3"
	eventExpected := &clienttypes.InboundEvent{
		SenderChainID:    chain.ChainId,
		Sender:           sender,
		Receiver:         "0x6dA30bFA65E85a16b05bCE3846339ed2BC746316",
		TxOrigin:         sender,
		Amount:           100000000,
		Memo:             []byte{},
		BlockNumber:      txResult.Slot,
		TxHash:           txHash,
		Index:            0, // not a EVM smart contract call
		CoinType:         coin.CoinType_Gas,
		Asset:            "", // no asset for gas token SOL
		IsCrossChainCall: false,
	}

	t.Run("should filter inbound event deposit SOL", func(t *testing.T) {
		events, err := observer.FilterInboundEvents(txResult, gatewayID, chain.ChainId, zerolog.Nop())
		require.NoError(t, err)

		// check result
		require.Len(t, events, 1)
		require.EqualValues(t, eventExpected, events[0])
	})
}

func Test_BuildInboundVoteMsgFromEvent(t *testing.T) {
	// create test observer
	chain := chains.SolanaDevnet
	params := sample.ChainParams(chain.ChainId)
	params.GatewayAddress = sample.SolanaAddress(t)
	zetacoreClient := mocks.NewZetacoreClient(t)
	zetacoreClient.WithKeys(&keys.Keys{}).WithZetaChain().WithPostVoteInbound("", "")

	database, err := db.NewFromSqliteInMemory(true)
	require.NoError(t, err)

	baseObserver, err := base.NewObserver(
		chain,
		*params,
		zetacoreClient,
		nil,
		1000,
		nil,
		database,
		base.DefaultLogger(),
	)
	require.NoError(t, err)

	ob, err := observer.New(baseObserver, nil, params.GatewayAddress)
	require.NoError(t, err)

	// create test compliance config
	cfg := config.Config{
		ComplianceConfig: config.ComplianceConfig{},
	}

	t.Run("should return vote msg for valid event", func(t *testing.T) {
		sender := sample.SolanaAddress(t)
		receiver := sample.EthAddress()
		message := sample.Bytes()
		event := sample.InboundEvent(chain.ChainId, sender, receiver.Hex(), 1280, message)

		msg := ob.BuildInboundVoteMsgFromEvent(event)
		require.NotNil(t, msg)
		require.Equal(t, sender, msg.Sender)
		require.Equal(t, receiver.Hex(), msg.Receiver)
		require.Equal(t, hex.EncodeToString(message), msg.Message)
	})

	t.Run("should return nil if event is not processable", func(t *testing.T) {
		sender := sample.SolanaAddress(t)
		receiver := sample.SolanaAddress(t)
		event := sample.InboundEvent(chain.ChainId, sender, receiver, 1280, nil)

		// restrict sender
		cfg.ComplianceConfig.RestrictedAddresses = []string{sender}
		config.LoadComplianceConfig(cfg)

		msg := ob.BuildInboundVoteMsgFromEvent(event)
		require.Nil(t, msg)
	})
}

func Test_IsEventProcessable(t *testing.T) {
	// prepare params
	chain := chains.SolanaDevnet
	params := sample.ChainParams(chain.ChainId)
	params.GatewayAddress = sample.SolanaAddress(t)

	// create test observer
	ob := MockSolanaObserver(t, chain, nil, *params, nil, nil)

	// setup compliance config
	cfg := config.Config{
		ComplianceConfig: sample.ComplianceConfig(),
	}
	config.LoadComplianceConfig(cfg)

	// test cases
	tests := []struct {
		name   string
		event  clienttypes.InboundEvent
		result bool
	}{
		{
			name:   "should return true for processable event",
			event:  clienttypes.InboundEvent{Sender: sample.SolanaAddress(t), Receiver: sample.SolanaAddress(t)},
			result: true,
		},
		{
			name:   "should return false on donation message",
			event:  clienttypes.InboundEvent{Memo: []byte(constant.DonationMessage)},
			result: false,
		},
		{
			name: "should return false on compliance violation",
			event: clienttypes.InboundEvent{
				Sender:   sample.RestrictedSolAddressTest,
				Receiver: sample.EthAddress().Hex(),
			},
			result: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ob.IsEventProcessable(tt.event)
			require.Equal(t, tt.result, result)
		})
	}
}
