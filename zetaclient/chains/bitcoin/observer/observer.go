// Package observer implements the Bitcoin chain observer
package observer

import (
	"context"
	"fmt"
	"sync/atomic"
	"time"

	"github.com/btcsuite/btcd/btcjson"
	"github.com/btcsuite/btcd/btcutil"
	"github.com/btcsuite/btcd/chaincfg"
	hash "github.com/btcsuite/btcd/chaincfg/chainhash"
	"github.com/btcsuite/btcd/wire"
	"github.com/pkg/errors"
	"github.com/rs/zerolog"

	"github.com/zeta-chain/node/pkg/chains"
	"github.com/zeta-chain/node/zetaclient/chains/base"
)

type RPC interface {
	Healthcheck(ctx context.Context, tssAddress btcutil.Address) (time.Time, error)

	GetBlockCount(ctx context.Context) (int64, error)
	GetBlockHash(ctx context.Context, blockHeight int64) (*hash.Hash, error)
	GetBlockHeader(ctx context.Context, hash *hash.Hash) (*wire.BlockHeader, error)
	GetBlockVerbose(ctx context.Context, hash *hash.Hash) (*btcjson.GetBlockVerboseTxResult, error)

	GetRawTransaction(ctx context.Context, hash *hash.Hash) (*btcutil.Tx, error)
	GetRawTransactionVerbose(ctx context.Context, hash *hash.Hash) (*btcjson.TxRawResult, error)
	GetRawTransactionResult(
		ctx context.Context,
		hash *hash.Hash,
		res *btcjson.GetTransactionResult,
	) (btcjson.TxRawResult, error)

	GetEstimatedFeeRate(ctx context.Context, confTarget int64) (int64, error)
	GetTransactionFeeAndRate(ctx context.Context, tx *btcjson.TxRawResult) (int64, int64, error)

	EstimateSmartFee(
		ctx context.Context,
		confTarget int64,
		mode *btcjson.EstimateSmartFeeMode,
	) (*btcjson.EstimateSmartFeeResult, error)

	ListUnspentMinMaxAddresses(
		ctx context.Context,
		minConf, maxConf int,
		addresses []btcutil.Address,
	) ([]btcjson.ListUnspentResult, error)

	GetBlockHeightByStr(ctx context.Context, blockHash string) (int64, error)
	GetTransactionByStr(ctx context.Context, hash string) (*hash.Hash, *btcjson.GetTransactionResult, error)
}

const (
	// RegnetStartBlock is the hardcoded start block for regnet
	RegnetStartBlock = 100

	// BigValueSats contains the threshold to determine a big value in Bitcoin represents 2 BTC
	BigValueSats = 200000000

	// BigValueConfirmationCount represents the number of confirmation necessary for bigger values: 6 confirmations
	BigValueConfirmationCount = 6
)

// Logger contains list of loggers used by Bitcoin chain observer
type Logger struct {
	// base.Logger contains a list of base observer loggers
	base.ObserverLogger

	// UTXOs is the logger for UTXOs management
	UTXOs zerolog.Logger
}

// BTCBlockNHeader contains bitcoin block and the header
type BTCBlockNHeader struct {
	Header *wire.BlockHeader
	Block  *btcjson.GetBlockVerboseTxResult
}

// Observer is the Bitcoin chain observer
type Observer struct {
	// base.Observer implements the base chain observer
	*base.Observer

	// netParams contains the Bitcoin network parameters
	netParams *chaincfg.Params

	// btcClient is the Bitcoin RPC client that interacts with the Bitcoin node
	rpc RPC

	// pendingNonce is the outbound artificial pending nonce
	pendingNonce uint64

	// utxos contains the UTXOs owned by the TSS address
	utxos []btcjson.ListUnspentResult

	// tssOutboundHashes keeps track of outbound hashes sent from TSS address
	tssOutboundHashes map[string]bool

	// includedTxResults indexes tx results with the outbound tx identifier
	includedTxResults map[string]*btcjson.GetTransactionResult

	// broadcastedTx indexes the outbound hash with the outbound tx identifier
	broadcastedTx map[string]string

	// nodeEnabled indicates whether BTC node is enabled (might be disabled during certain E2E tests)
	// We assume it's true by default. The flag is updated on each ObserveInbound call.
	nodeEnabled atomic.Bool

	// logger contains the loggers used by the bitcoin observer
	logger Logger
}

// New BTC Observer constructor.
func New(chain chains.Chain, baseObserver *base.Observer, rpc RPC) (*Observer, error) {
	// get the bitcoin network params
	netParams, err := chains.BitcoinNetParamsFromChainID(chain.ChainId)
	if err != nil {
		return nil, errors.Wrapf(err, "unable to get BTC net params")
	}

	// create bitcoin observer
	ob := &Observer{
		Observer:          baseObserver,
		netParams:         netParams,
		rpc:               rpc,
		utxos:             []btcjson.ListUnspentResult{},
		tssOutboundHashes: make(map[string]bool),
		includedTxResults: make(map[string]*btcjson.GetTransactionResult),
		broadcastedTx:     make(map[string]string),
		logger: Logger{
			ObserverLogger: *baseObserver.Logger(),
			UTXOs:          baseObserver.Logger().Chain.With().Str("module", "utxos").Logger(),
		},
	}

	ob.nodeEnabled.Store(true)

	// load last scanned block
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err = ob.LoadLastBlockScanned(ctx); err != nil {
		return nil, errors.Wrap(err, "unable to load last scanned block")
	}

	// load broadcasted transactions
	if err = ob.loadBroadcastedTxMap(); err != nil {
		return nil, errors.Wrap(err, "unable to load broadcasted tx map")
	}

	return ob, nil
}

// GetPendingNonce returns the artificial pending nonce
// Note: pending nonce is accessed concurrently
func (ob *Observer) GetPendingNonce() uint64 {
	ob.Mu().Lock()
	defer ob.Mu().Unlock()
	return ob.pendingNonce
}

func (ob *Observer) setPendingNonce(nonce uint64) {
	ob.Mu().Lock()
	defer ob.Mu().Unlock()
	ob.pendingNonce = nonce
}

// GetBlockByNumberCached gets cached block (and header) by block number
func (ob *Observer) GetBlockByNumberCached(ctx context.Context, blockNumber int64) (*BTCBlockNHeader, error) {
	if result, ok := ob.BlockCache().Get(blockNumber); ok {
		if block, ok := result.(*BTCBlockNHeader); ok {
			return block, nil
		}
		return nil, errors.New("cached value is not of type *BTCBlockNHeader")
	}

	// Get the block hash
	hash, err := ob.rpc.GetBlockHash(ctx, blockNumber)
	if err != nil {
		return nil, err
	}
	// Get the block header
	header, err := ob.rpc.GetBlockHeader(ctx, hash)
	if err != nil {
		return nil, err
	}
	// Get the block with verbose transactions
	block, err := ob.rpc.GetBlockVerbose(ctx, hash)
	if err != nil {
		return nil, err
	}
	blockNheader := &BTCBlockNHeader{
		Header: header,
		Block:  block,
	}
	ob.BlockCache().Add(blockNumber, blockNheader)
	ob.BlockCache().Add(hash, blockNheader)
	return blockNheader, nil
}

// IsTSSTransaction checks if a given transaction was sent by TSS itself.
// An unconfirmed transaction is safe to spend only if it was sent by TSS and verified by ourselves.
func (ob *Observer) IsTSSTransaction(txid string) bool {
	_, found := ob.tssOutboundHashes[txid]
	return found
}

// GetBroadcastedTx gets successfully broadcasted transaction by nonce
func (ob *Observer) GetBroadcastedTx(nonce uint64) (string, bool) {
	ob.Mu().Lock()
	defer ob.Mu().Unlock()

	outboundID := ob.OutboundID(nonce)
	txHash, found := ob.broadcastedTx[outboundID]
	return txHash, found
}

func (ob *Observer) isNodeEnabled() bool {
	return ob.nodeEnabled.Load()
}

// updateLastBlock is a helper function to update the last block number.
// Note: keep last block up-to-date helps to avoid inaccurate confirmation.
func (ob *Observer) updateLastBlock(ctx context.Context) error {
	blockNumber, err := ob.rpc.GetBlockCount(ctx)
	if err != nil {
		return errors.Wrapf(err, "error getting block number")
	}
	if blockNumber < 0 {
		return fmt.Errorf("block number is negative: %d", blockNumber)
	}

	// 0 will be returned if the node is not synced
	if blockNumber == 0 {
		ob.nodeEnabled.Store(false)
		ob.Logger().Chain.Debug().Err(err).Msg("Bitcoin node is not enabled")
		return nil
	}
	ob.nodeEnabled.Store(true)

	// #nosec G115 checked positive
	if uint64(blockNumber) < ob.LastBlock() {
		return fmt.Errorf("block number should not decrease: current %d last %d", blockNumber, ob.LastBlock())
	}
	ob.WithLastBlock(uint64(blockNumber))

	return nil
}
