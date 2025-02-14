/**
 * This script will deploy Flare systems protocol and FTSO scaling contracts.
 * It will output, on stdout, a json encoded list of contracts
 * that were deployed. It will write out to stderr, status info
 * as it executes.
 * @dev Do not send anything out via console.log unless it is
 * json defining the created contracts.
 */

import { HardhatRuntimeEnvironment } from "hardhat/types";
import { ChainParameters } from "../chain-config/chain-parameters";
import { Contracts } from "./Contracts";
import { spewNewContractInfo } from './deploy-utils';
import { ISigningPolicy, SigningPolicy } from '../../scripts/libs/protocol/SigningPolicy';
import { FtsoConfigurations } from '../../scripts/libs/protocol/FtsoConfigurations';
import { FtsoFeedIdConverterContract } from '../../typechain-truffle/contracts/ftso/implementation/FtsoFeedIdConverter';
import { generateOffers, runOfferRewards } from './offer-rewards';
import { RelayInitialConfig } from '../utils/RelayInitialConfig';
import { EntityManagerContract } from '../../typechain-truffle/contracts/protocol/implementation/EntityManager';
import { NodePossessionVerifierContract } from '../../typechain-truffle/contracts/protocol/implementation/NodePossessionVerifier';
import { VoterRegistryContract } from '../../typechain-truffle/contracts/protocol/implementation/VoterRegistry';
import { FlareSystemsCalculatorContract } from '../../typechain-truffle/contracts/protocol/implementation/FlareSystemsCalculator';
import { FlareSystemsManagerContract } from '../../typechain-truffle/contracts/protocol/implementation/FlareSystemsManager';
import { RewardManagerContract } from '../../typechain-truffle/contracts/protocol/implementation/RewardManager';
import { FtsoRewardManagerProxyContract } from '../../typechain-truffle/contracts/fscV1/implementation/FtsoRewardManagerProxy';
import { SubmissionContract } from '../../typechain-truffle/contracts/protocol/implementation/Submission';
import { WNatDelegationFeeContract } from '../../typechain-truffle/contracts/protocol/implementation/WNatDelegationFee';
import { FtsoInflationConfigurationsContract } from '../../typechain-truffle/contracts/ftso/implementation/FtsoInflationConfigurations';
import { FtsoRewardOffersManagerContract } from '../../typechain-truffle/contracts/ftso/implementation/FtsoRewardOffersManager';
import { FtsoFeedDecimalsContract } from '../../typechain-truffle/contracts/ftso/implementation/FtsoFeedDecimals';
import { FtsoFeedPublisherContract } from '../../typechain-truffle/contracts/ftso/implementation/FtsoFeedPublisher';
import { RelayContract } from '../../typechain-truffle/contracts/protocol/implementation/Relay';
import { FdcHubContract } from "../../typechain-truffle/contracts/fdc/implementation/FdcHub";
import { FdcInflationConfigurationsContract } from "../../typechain-truffle/contracts/fdc/implementation/FdcInflationConfigurations";
import { FdcRequestFeeConfigurationsContract } from "../../typechain-truffle/contracts/fdc/implementation/FdcRequestFeeConfigurations";

let fs = require("fs");

export async function deployContracts(
  hre: HardhatRuntimeEnvironment,
  oldContracts: Contracts,
  contracts: Contracts,
  parameters: ChainParameters,
  quiet: boolean = false
) {
  const web3 = hre.web3;
  const artifacts = hre.artifacts;
  const BN = web3.utils.toBN;

  const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

  const EntityManager: EntityManagerContract = artifacts.require("EntityManager");
  const NodePossessionVerifier: NodePossessionVerifierContract = artifacts.require("NodePossessionVerifier");
  const VoterRegistry: VoterRegistryContract = artifacts.require("VoterRegistry");
  const FlareSystemsCalculator: FlareSystemsCalculatorContract = artifacts.require("FlareSystemsCalculator");
  const FlareSystemsManager: FlareSystemsManagerContract = artifacts.require("FlareSystemsManager");
  const RewardManager: RewardManagerContract = artifacts.require("RewardManager");
  const FtsoRewardManagerProxy: FtsoRewardManagerProxyContract = artifacts.require("FtsoRewardManagerProxy");
  const Submission: SubmissionContract = artifacts.require("Submission");
  const WNatDelegationFee: WNatDelegationFeeContract = artifacts.require("WNatDelegationFee");
  const FtsoInflationConfigurations: FtsoInflationConfigurationsContract =
    artifacts.require("FtsoInflationConfigurations");
  const FtsoRewardOffersManager: FtsoRewardOffersManagerContract = artifacts.require("FtsoRewardOffersManager");
  const FtsoFeedDecimals: FtsoFeedDecimalsContract = artifacts.require("FtsoFeedDecimals");
  const FtsoFeedPublisher: FtsoFeedPublisherContract = artifacts.require("FtsoFeedPublisher");
  const FtsoFeedIdConverter: FtsoFeedIdConverterContract = artifacts.require("FtsoFeedIdConverter");
  const Relay: RelayContract = artifacts.require("Relay");
  const Supply = artifacts.require("IISupplyGovernance");
  const FdcHub: FdcHubContract = artifacts.require("FdcHub");
  const FdcInflationConfigurations: FdcInflationConfigurationsContract = artifacts.require("FdcInflationConfigurations");
  const FdcRequestFeeConfigurations: FdcRequestFeeConfigurationsContract = artifacts.require("FdcRequestFeeConfigurations");

  // Define accounts in play for the deployment process
  let deployerAccount: any;

  try {
    deployerAccount = web3.eth.accounts.privateKeyToAccount(parameters.deployerPrivateKey);
  } catch (e) {
    throw Error("Check .env file, if the private keys are correct and are prefixed by '0x'.\n" + e);
  }

  // Wire up the default account that will do the deployment
  web3.eth.defaultAccount = deployerAccount.address;

  const governanceSettings = oldContracts.getContractAddress(Contracts.GOVERNANCE_SETTINGS);
  const addressUpdater = oldContracts.getContractAddress(Contracts.ADDRESS_UPDATER);
  const pChainStakeMirror = parameters.pChainStakeEnabled
    ? oldContracts.getContractAddress(Contracts.P_CHAIN_STAKE_MIRROR)
    : ZERO_ADDRESS;
  const wNat = oldContracts.getContractAddress(Contracts.WNAT);
  const claimSetupManager = oldContracts.getContractAddress(Contracts.CLAIM_SETUP_MANAGER);
  const inflation = oldContracts.getContractAddress(Contracts.INFLATION);
  const ftsoRewardManager = oldContracts.getContractAddress(Contracts.FTSO_REWARD_MANAGER);
  const cleanupBlockNumberManager = oldContracts.getContractAddress(Contracts.CLEANUP_BLOCK_NUMBER_MANAGER);

  const entityManager = await EntityManager.new(
    governanceSettings,
    deployerAccount.address,
    parameters.maxNodeIdsPerEntity
  );
  spewNewContractInfo(contracts, null, EntityManager.contractName, `EntityManager.sol`, entityManager.address, quiet);

  const nodePossessionVerifier = await NodePossessionVerifier.new();
  spewNewContractInfo(
    contracts,
    null,
    NodePossessionVerifier.contractName,
    `NodePossessionVerifier.sol`,
    nodePossessionVerifier.address,
    quiet
  );

  await entityManager.setNodePossessionVerifier(nodePossessionVerifier.address);

  const currentBlock = await web3.eth.getBlock(await web3.eth.getBlockNumber());
  const currentBlockTs = BN(currentBlock.timestamp);
  if (!quiet) {
    console.error(`Current network time is ${new Date(currentBlockTs.toNumber() * 1000).toISOString()}.`);
  }

  let firstVotingRoundStartTs = BN(parameters.firstVotingRoundStartTs);
  if (firstVotingRoundStartTs.eqn(0) || firstVotingRoundStartTs.gt(currentBlockTs)) {
    // Get the timestamp for the just mined block
    firstVotingRoundStartTs = currentBlockTs;
    if (!quiet) {
      console.error(`Using current block timestamp ${currentBlockTs} as first voting round start timestamp.`);
    }
  } else {
    if (!quiet) {
      console.error(
        `Using firstVotingRoundStartTs parameter ${parameters.firstVotingRoundStartTs} as first voting round start timestamp.`
      );
    }
  }
  const initialRewardEpochId = currentBlockTs
    .sub(firstVotingRoundStartTs)
    .subn(parameters.firstRewardEpochStartVotingRoundId * parameters.votingEpochDurationSeconds)
    .divn(parameters.votingEpochDurationSeconds * parameters.rewardEpochDurationInVotingEpochs)
    .addn(parameters.initialRewardEpochOffset)
    .toNumber();
  const initialRewardEpochStartVotingRoundId =
    initialRewardEpochId * parameters.rewardEpochDurationInVotingEpochs + parameters.firstRewardEpochStartVotingRoundId;

  fs.writeFileSync("deployment/deploys/initialRewardEpochId.txt", initialRewardEpochId.toString());

  if (!quiet) {
    console.error(
      `Initial reward epoch id: ${initialRewardEpochId}. Start voting round id: ${initialRewardEpochStartVotingRoundId}.`
    );
  }

  const voterRegistry = await VoterRegistry.new(
    governanceSettings,
    deployerAccount.address,
    deployerAccount.address, // tmp address updater
    parameters.maxVotersPerRewardEpoch,
    initialRewardEpochId,
    0,
    0,
    parameters.initialVoters,
    parameters.initialNormalisedWeights
  );
  spewNewContractInfo(contracts, null, VoterRegistry.contractName, `VoterRegistry.sol`, voterRegistry.address, quiet);

  const flareSystemsCalculator = await FlareSystemsCalculator.new(
    governanceSettings,
    deployerAccount.address,
    deployerAccount.address, // tmp address updater
    parameters.wNatCapPPM,
    parameters.signingPolicySignNonPunishableDurationSeconds,
    parameters.signingPolicySignNonPunishableDurationBlocks,
    parameters.signingPolicySignNoRewardsDurationBlocks
  );
  spewNewContractInfo(
    contracts,
    null,
    FlareSystemsCalculator.contractName,
    `FlareSystemsCalculator.sol`,
    flareSystemsCalculator.address,
    quiet
  );

  const initialSigningPolicy: ISigningPolicy = {
    rewardEpochId: initialRewardEpochId,
    startVotingRoundId: initialRewardEpochStartVotingRoundId,
    threshold: parameters.initialThreshold,
    seed: web3.utils.keccak256("123"),
    voters: parameters.initialVoters,
    weights: parameters.initialNormalisedWeights,
  };

  const initialSettings = {
    initialRandomVotePowerBlockSelectionSize: parameters.initialRandomVotePowerBlockSelectionSize,
    initialRewardEpochId: initialRewardEpochId,
    initialRewardEpochThreshold: parameters.initialThreshold,
  };

  const updatableSettings = {
    newSigningPolicyInitializationStartSeconds: parameters.newSigningPolicyInitializationStartSeconds,
    randomAcquisitionMaxDurationSeconds: parameters.randomAcquisitionMaxDurationSeconds,
    randomAcquisitionMaxDurationBlocks: parameters.randomAcquisitionMaxDurationBlocks,
    newSigningPolicyMinNumberOfVotingRoundsDelay: parameters.newSigningPolicyMinNumberOfVotingRoundsDelay,
    voterRegistrationMinDurationSeconds: parameters.voterRegistrationMinDurationSeconds,
    voterRegistrationMinDurationBlocks: parameters.voterRegistrationMinDurationBlocks,
    submitUptimeVoteMinDurationSeconds: parameters.submitUptimeVoteMinDurationSeconds,
    submitUptimeVoteMinDurationBlocks: parameters.submitUptimeVoteMinDurationBlocks,
    signingPolicyThresholdPPM: parameters.signingPolicyThresholdPPM,
    signingPolicyMinNumberOfVoters: parameters.signingPolicyMinNumberOfVoters,
    rewardExpiryOffsetSeconds: parameters.rewardExpiryOffsetSeconds,
  };

  const flareSystemsManager = await FlareSystemsManager.new(
    governanceSettings,
    deployerAccount.address,
    deployerAccount.address, // tmp address updater
    oldContracts.getContractAddress(Contracts.FLARE_DAEMON),
    updatableSettings,
    firstVotingRoundStartTs,
    parameters.votingEpochDurationSeconds,
    parameters.firstRewardEpochStartVotingRoundId,
    parameters.rewardEpochDurationInVotingEpochs,
    initialSettings
  );
  spewNewContractInfo(
    contracts,
    null,
    FlareSystemsManager.contractName,
    `FlareSystemsManager.sol`,
    flareSystemsManager.address,
    quiet
  );

  const rewardManager = await RewardManager.new(
    governanceSettings,
    deployerAccount.address,
    deployerAccount.address, // tmp address updater
    ZERO_ADDRESS,
    parameters.rewardManagerId
  );
  spewNewContractInfo(contracts, null, RewardManager.contractName, `RewardManager.sol`, rewardManager.address, quiet);

  const ftsoRewardManagerProxy = await FtsoRewardManagerProxy.new(
    governanceSettings,
    deployerAccount.address,
    deployerAccount.address, // tmp address updater
    ftsoRewardManager
  );
  spewNewContractInfo(contracts, null, "FtsoRewardManager", `FtsoRewardManagerProxy.sol`, ftsoRewardManagerProxy.address, quiet);

  const relayInitialConfig: RelayInitialConfig = {
    initialRewardEpochId: initialSigningPolicy.rewardEpochId,
    startingVotingRoundIdForInitialRewardEpochId: initialSigningPolicy.startVotingRoundId,
    initialSigningPolicyHash: SigningPolicy.hash(initialSigningPolicy),
    randomNumberProtocolId: parameters.ftsoProtocolId,
    firstVotingRoundStartTs: firstVotingRoundStartTs.toNumber(),
    votingEpochDurationSeconds: parameters.votingEpochDurationSeconds,
    firstRewardEpochStartVotingRoundId: parameters.firstRewardEpochStartVotingRoundId,
    rewardEpochDurationInVotingEpochs: parameters.rewardEpochDurationInVotingEpochs,
    thresholdIncreaseBIPS: parameters.relayThresholdIncreaseBIPS,
    messageFinalizationWindowInRewardEpochs: parameters.messageFinalizationWindowInRewardEpochs,
    feeCollectionAddress: ZERO_ADDRESS,
    feeConfigs: []
  }

  const relay = await Relay.new(
    relayInitialConfig,
    flareSystemsManager.address
  );

  spewNewContractInfo(contracts, null, Relay.contractName, `Relay.sol`, relay.address, quiet);

  // get the submission contract
  const submission = await Submission.at(contracts.getContractAddress(Contracts.SUBMISSION));

  const wNatDelegationFee = await WNatDelegationFee.new(
    deployerAccount.address, // tmp address updater
    parameters.feePercentageUpdateOffset,
    parameters.defaultFeePercentageBIPS
  );
  spewNewContractInfo(
    contracts,
    null,
    WNatDelegationFee.contractName,
    `WNatDelegationFee.sol`,
    wNatDelegationFee.address,
    quiet
  );

  const ftsoInflationConfigurations = await FtsoInflationConfigurations.new(
    governanceSettings,
    deployerAccount.address
  );
  spewNewContractInfo(
    contracts,
    null,
    FtsoInflationConfigurations.contractName,
    `FtsoInflationConfigurations.sol`,
    ftsoInflationConfigurations.address,
    quiet
  );

  const ftsoRewardOffersManager = await FtsoRewardOffersManager.new(
    governanceSettings,
    deployerAccount.address,
    deployerAccount.address, // tmp address updater
    0 // temp fee
  );
  spewNewContractInfo(
    contracts,
    null,
    FtsoRewardOffersManager.contractName,
    `FtsoRewardOffersManager.sol`,
    ftsoRewardOffersManager.address,
    quiet
  );

  const ftsoFeedDecimals = await FtsoFeedDecimals.new(
    governanceSettings,
    deployerAccount.address,
    deployerAccount.address, // tmp address updater
    parameters.decimalsUpdateOffset,
    parameters.defaultDecimals,
    initialRewardEpochId,
    parameters.feedDecimalsList.map(fd => {
      return {
        feedId: FtsoConfigurations.encodeFeedId(fd.feedId),
        decimals: fd.decimals,
      };
    })
  );
  spewNewContractInfo(
    contracts,
    null,
    FtsoFeedDecimals.contractName,
    `FtsoFeedDecimals.sol`,
    ftsoFeedDecimals.address,
    quiet
  );

  const ftsoFeedPublisher = await FtsoFeedPublisher.new(
    governanceSettings,
    deployerAccount.address,
    deployerAccount.address, // tmp address updater
    parameters.ftsoProtocolId,
    parameters.feedsHistorySize
  );
  spewNewContractInfo(
    contracts,
    null,
    FtsoFeedPublisher.contractName,
    `FtsoFeedPublisher.sol`,
    ftsoFeedPublisher.address,
    quiet
  );

  const ftsoFeedIdConverter = await FtsoFeedIdConverter.new();
  spewNewContractInfo(
    contracts,
    null,
    FtsoFeedIdConverter.contractName,
    `FtsoFeedIdConverter.sol`,
    ftsoFeedIdConverter.address,
    quiet
  );

  const fdcHub = await FdcHub.new(governanceSettings, deployerAccount.address, deployerAccount.address, parameters.fdcRequestsOffsetSeconds);
  spewNewContractInfo(contracts, null, FdcHub.contractName, `FdcHub.sol`, fdcHub.address, quiet);

  const fdcInflationConfigurations = await FdcInflationConfigurations.new(governanceSettings, deployerAccount.address, deployerAccount.address);
  spewNewContractInfo(contracts, null, FdcInflationConfigurations.contractName, `FdcInflationConfigurations.sol`, fdcInflationConfigurations.address, quiet);

  const fdcRequestFeeConfigurations = await FdcRequestFeeConfigurations.new(governanceSettings, deployerAccount.address);
  spewNewContractInfo(contracts, null, FdcRequestFeeConfigurations.contractName, `FdcRequestFeeConfigurations.sol`, fdcRequestFeeConfigurations.address, quiet);

  if (parameters.pChainStakeEnabled) {
    await flareSystemsCalculator.enablePChainStakeMirror();
    await rewardManager.enablePChainStakeMirror();
  }

  await voterRegistry.updateContractAddresses(
    encodeContractNames([
      Contracts.ADDRESS_UPDATER,
      Contracts.FLARE_SYSTEMS_MANAGER,
      Contracts.ENTITY_MANAGER,
      Contracts.FLARE_SYSTEMS_CALCULATOR,
    ]),
    [addressUpdater, flareSystemsManager.address, entityManager.address, flareSystemsCalculator.address]
  );

  await flareSystemsCalculator.updateContractAddresses(
    encodeContractNames([
      Contracts.ADDRESS_UPDATER,
      Contracts.FLARE_SYSTEMS_MANAGER,
      Contracts.ENTITY_MANAGER,
      Contracts.WNAT_DELEGATION_FEE,
      Contracts.VOTER_REGISTRY,
      Contracts.P_CHAIN_STAKE_MIRROR,
      Contracts.WNAT,
    ]),
    [
      addressUpdater,
      flareSystemsManager.address,
      entityManager.address,
      wNatDelegationFee.address,
      voterRegistry.address,
      pChainStakeMirror,
      wNat,
    ]
  );

  await flareSystemsManager.updateContractAddresses(
    encodeContractNames([Contracts.ADDRESS_UPDATER, Contracts.VOTER_REGISTRY, Contracts.SUBMISSION, Contracts.RELAY, Contracts.REWARD_MANAGER, Contracts.CLEANUP_BLOCK_NUMBER_MANAGER]),
    [addressUpdater, voterRegistry.address, submission.address, relay.address, rewardManager.address, cleanupBlockNumberManager]
  );

  await rewardManager.updateContractAddresses(
    encodeContractNames([Contracts.ADDRESS_UPDATER, Contracts.VOTER_REGISTRY, Contracts.CLAIM_SETUP_MANAGER, Contracts.FLARE_SYSTEMS_MANAGER, Contracts.FLARE_SYSTEMS_CALCULATOR, Contracts.P_CHAIN_STAKE_MIRROR, Contracts.WNAT, Contracts.FTSO_REWARD_MANAGER]),
    [addressUpdater, voterRegistry.address, claimSetupManager, flareSystemsManager.address, flareSystemsCalculator.address, pChainStakeMirror, wNat, ftsoRewardManagerProxy.address]
  );

  await ftsoRewardManagerProxy.updateContractAddresses(
    encodeContractNames([Contracts.ADDRESS_UPDATER, Contracts.REWARD_MANAGER, Contracts.FLARE_SYSTEMS_MANAGER, Contracts.WNAT_DELEGATION_FEE, Contracts.WNAT, Contracts.CLAIM_SETUP_MANAGER]),
    [addressUpdater, rewardManager.address, flareSystemsManager.address, wNatDelegationFee.address, wNat, claimSetupManager]
  );

  if (parameters.testDeployment) {
    await submission.updateContractAddresses(
      encodeContractNames([Contracts.ADDRESS_UPDATER, Contracts.FLARE_SYSTEMS_MANAGER, Contracts.RELAY]),
      [addressUpdater, flareSystemsManager.address, relay.address],
      { from: parameters.governancePublicKey }
    );
  }

  await wNatDelegationFee.updateContractAddresses(
    encodeContractNames([Contracts.ADDRESS_UPDATER, Contracts.FLARE_SYSTEMS_MANAGER]),
    [addressUpdater, flareSystemsManager.address]
  );

  await ftsoRewardOffersManager.updateContractAddresses(
    encodeContractNames([
      Contracts.ADDRESS_UPDATER,
      Contracts.FLARE_SYSTEMS_MANAGER,
      Contracts.REWARD_MANAGER,
      Contracts.FTSO_INFLATION_CONFIGURATIONS,
      Contracts.FTSO_FEED_DECIMALS,
      Contracts.INFLATION,
    ]),
    [
      addressUpdater,
      flareSystemsManager.address,
      rewardManager.address,
      ftsoInflationConfigurations.address,
      ftsoFeedDecimals.address,
      inflation,
    ]
  );

  await ftsoFeedDecimals.updateContractAddresses(
    encodeContractNames([Contracts.ADDRESS_UPDATER, Contracts.FLARE_SYSTEMS_MANAGER]),
    [addressUpdater, flareSystemsManager.address]
  );

  await ftsoFeedPublisher.updateContractAddresses(encodeContractNames([Contracts.ADDRESS_UPDATER, Contracts.RELAY]), [
    addressUpdater,
    relay.address,
  ]);

  await fdcHub.updateContractAddresses(
    encodeContractNames([
      Contracts.ADDRESS_UPDATER,
      Contracts.FLARE_SYSTEMS_MANAGER,
      Contracts.REWARD_MANAGER,
      Contracts.FTSO_INFLATION_CONFIGURATIONS,
      Contracts.FTSO_FEED_DECIMALS,
      Contracts.INFLATION,
      Contracts.FDC_INFLATION_CONFIGURATIONS,
      Contracts.FDC_REQUEST_FEE_CONFIGURATIONS
    ]),
    [
      addressUpdater,
      flareSystemsManager.address,
      rewardManager.address,
      ftsoInflationConfigurations.address,
      ftsoFeedDecimals.address,
      inflation,
      fdcInflationConfigurations.address,
      fdcRequestFeeConfigurations.address
    ]
  );

  await fdcInflationConfigurations.updateContractAddresses(
    encodeContractNames([Contracts.ADDRESS_UPDATER, Contracts.FDC_REQUEST_FEE_CONFIGURATIONS]),
    [addressUpdater, fdcRequestFeeConfigurations.address]
  );

  // set initial voter data on entity manager
  await entityManager.setInitialVoterData(parameters.initialVoterData);

  // set ftso inflation configurations
  for (const ftsoInflationConfiguration of parameters.ftsoInflationConfigurations) {
    const configuration = {
      feedIds: FtsoConfigurations.encodeFeedIds(ftsoInflationConfiguration.feedIds),
      inflationShare: ftsoInflationConfiguration.inflationShare,
      minRewardedTurnoutBIPS: ftsoInflationConfiguration.minRewardedTurnoutBIPS,
      primaryBandRewardSharePPM: ftsoInflationConfiguration.primaryBandRewardSharePPM,
      secondaryBandWidthPPMs: FtsoConfigurations.encodeSecondaryBandWidthPPMs(
        ftsoInflationConfiguration.secondaryBandWidthPPMs
      ),
      mode: ftsoInflationConfiguration.mode,
    };
    await ftsoInflationConfigurations.addFtsoConfiguration(configuration);
  }

  // enable ftso reward manager proxy
  await ftsoRewardManagerProxy.enable();

  // set reward offers manager list
  await rewardManager.setRewardOffersManagerList([ftsoRewardOffersManager.address, fdcHub.address]);

  // set rewards offer switchover trigger contracts
  await flareSystemsManager.setRewardEpochSwitchoverTriggerContracts([ftsoRewardOffersManager.address, fdcHub.address]);

  // set initial data on reward manager
  await rewardManager.setInitialRewardData();

  // activate reward manager
  await rewardManager.activate();

  // send initial offers
  for (const ftsoInflationConfiguration of parameters.ftsoInflationConfigurations) {
    const offers = generateOffers(ftsoInflationConfiguration.feedIds, 0, deployerAccount.address);
    await runOfferRewards(initialRewardEpochId + 1, ftsoRewardOffersManager, offers, deployerAccount.address);
  }

  // update minimalRewardsOfferValueNAT
  await ftsoRewardOffersManager.setMinimalRewardsOfferValue(
    BN(parameters.minimalRewardsOfferValueNAT).mul(BN(10).pow(BN(18)))
  );

  // set fdc request fee configurations
  for (const fdcRequestFee of parameters.fdcRequestFees) {
    await fdcRequestFeeConfigurations.setTypeAndSourceFee(
      web3.utils.utf8ToHex(fdcRequestFee.attestationType).padEnd(66, "0"),
      web3.utils.utf8ToHex(fdcRequestFee.source).padEnd(66, "0"),
      fdcRequestFee.feeWei
    );
  }

  // set fdc inflation configurations
  const fdcConfigurations = [];
  for (const fdcInflationConfiguration of parameters.fdcInflationConfigurations) {
    const configuration = {
      attestationType: web3.utils.utf8ToHex(fdcInflationConfiguration.attestationType).padEnd(66, "0"),
      source: web3.utils.utf8ToHex(fdcInflationConfiguration.source).padEnd(66, "0"),
      inflationShare: fdcInflationConfiguration.inflationShare,
      minRequestsThreshold: fdcInflationConfiguration.minRequestsThreshold,
      mode: fdcInflationConfiguration.mode,
    };
    fdcConfigurations.push(configuration);
  }
  await fdcInflationConfigurations.addFdcConfigurations(fdcConfigurations);

  if (parameters.testDeployment) {
    await rewardManager.enableClaims();
    const supply = await Supply.at(oldContracts.getContractAddress(Contracts.SUPPLY));
    await supply.addTokenPool(rewardManager.address, 0);
  }

  contracts.serialize();
  if (!quiet) {
    console.error("Deploy complete.");
  }

  function encodeContractNames(names: string[]): string[] {
    return names.map(name => encodeString(name));
  }

  function encodeString(text: string): string {
    return web3.utils.keccak256(web3.eth.abi.encodeParameters(["string"], [text]));
  }
}
