// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../../userInterfaces/LTS/FtsoV2Interface.sol";
import "../../userInterfaces/IFastUpdater.sol";
import "../../userInterfaces/IFastUpdatesConfiguration.sol";
import "../../userInterfaces/IFeeCalculator.sol";
import "../../userInterfaces/IRelay.sol";
import "../../governance/implementation/GovernedProxyImplementation.sol";
import "../../utils/implementation/AddressUpdatable.sol";
import "../../customFeeds/interface/IICustomFeed.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

contract FtsoV2 is FtsoV2Interface, UUPSUpgradeable, GovernedProxyImplementation, AddressUpdatable {
    using MerkleProof for bytes32[];

    struct CustomFeedData {
        IICustomFeed customFeed;
        uint96 index;  // index is 1-based, 0 means non-existent
    }
    struct FeedIdChange {
        bytes21 newFeedId;
        uint88 index;  // index is 1-based, 0 means non-existent
    }

    /// The FTSO protocol id.
    uint256 public constant FTSO_PROTOCOL_ID = 100;

    /// The FastUpdater contract.
    IFastUpdater public fastUpdater;
    /// The FastUpdatesConfiguration contract.
    IFastUpdatesConfiguration public fastUpdatesConfiguration;
    /// The FeeCalculator contract.
    IFeeCalculator public feeCalculator;
    /// The Relay contract.
    IRelay public relay;

    bytes21[] private customFeedIds;
    mapping(bytes21 feedId => CustomFeedData) private customFeedsData;
    bytes21[] private changedFeedIds;
    mapping(bytes21 oldFeedId => FeedIdChange) private feedIdChanges;

    /// Event emitted when a custom feed is added.
    event CustomFeedAdded(bytes21 indexed feedId, IICustomFeed customFeed);
    /// Event emitted when a custom feed is replaced.
    event CustomFeedReplaced(bytes21 indexed feedId, IICustomFeed oldCustomFeed, IICustomFeed newCustomFeed);
    /// Event emitted when a custom feed is removed.
    event CustomFeedRemoved(bytes21 indexed feedId);
    /// Event emitted when a feed id is changed (e.g. feed renamed).
    event FeedIdChanged(bytes21 indexed oldFeedId, bytes21 indexed newFeedId);

    /**
     * Constructor that initializes with invalid parameters to prevent direct deployment/updates.
     */
    constructor()
        GovernedProxyImplementation() AddressUpdatable(address(0))
    { }

    /**
     * Proxyable initialization method. Can be called only once, from the proxy constructor
     * (single call is assured by GovernedBase.initialise).
     */
    function initialize(
        IGovernanceSettings _governanceSettings,
        address _initialGovernance,
        address _addressUpdater
    )
        external
    {
        GovernedBase.initialise(_governanceSettings, _initialGovernance);
        AddressUpdatable.setAddressUpdaterValue(_addressUpdater);
    }

    /**
     * @inheritdoc FtsoV2Interface
     */
    function getFtsoProtocolId() external pure returns (uint256) {
        return FTSO_PROTOCOL_ID;
    }

    /**
     * @inheritdoc FtsoV2Interface
     */
    function verifyFeedData(FeedDataWithProof calldata _feedData) external view returns (bool) {
        bytes32 feedHash = keccak256(abi.encode(_feedData.body));
        bytes32 merkleRoot = relay.merkleRoots(FTSO_PROTOCOL_ID, _feedData.body.votingRoundId);
        require(_feedData.proof.verifyCalldata(merkleRoot, feedHash), "merkle proof invalid");
        return true;
    }

    /////////////////////////////// FEED_ID FUNCTIONS ///////////////////////////////

    /**
     * @inheritdoc FtsoV2Interface
     */
    function getSupportedFeedIds() external view returns (bytes21[] memory _feedIds) {
        bytes21[] memory fastUpdateFeedIds = fastUpdatesConfiguration.getFeedIds();
        uint256 unusedIndicesLength = fastUpdatesConfiguration.getUnusedIndices().length;
        // unusedIndicesLength <= fastUpdateFeedIds.length
        _feedIds = new bytes21[](fastUpdateFeedIds.length - unusedIndicesLength + customFeedIds.length);
        uint256 index = 0;
        // add fast update feed ids that are not removed (bytes21(0))
        for (uint256 i = 0; i < fastUpdateFeedIds.length; i++) {
            if (fastUpdateFeedIds[i] != bytes21(0)) {
                _feedIds[index] = fastUpdateFeedIds[i];
                index++;
            }
        }
        // add custom feed ids
        for (uint256 i = 0; i < customFeedIds.length; i++) {
            _feedIds[index] = customFeedIds[i];
            index++;
        }
    }

    /**
     * @inheritdoc FtsoV2Interface
     */
    function getFeedById(bytes21 _feedId) external payable returns (uint256, int8, uint64) {
        return _getFeedById(_feedId);
    }

    /**
     * @inheritdoc FtsoV2Interface
     */
    function getFeedsById(bytes21[] memory _feedIds)
        external payable
        returns(
            uint256[] memory,
            int8[] memory,
            uint64
        )
    {
        return _getFeedsById(_feedIds);
    }

    /**
     * @inheritdoc FtsoV2Interface
     */
    function getFeedByIdInWei(bytes21 _feedId)
        external payable
        returns (
            uint256 _value,
            uint64 _timestamp
        )
    {
        int8 decimals;
        (_value, decimals, _timestamp) = _getFeedById(_feedId);
        _value = _convertToWei(_value, decimals);
    }

    /**
     * @inheritdoc FtsoV2Interface
     */
    function getFeedsByIdInWei(bytes21[] memory _feedIds)
        external payable
        returns (
            uint256[] memory _values,
            uint64 _timestamp
        )
    {
        int8[] memory decimals;
        (_values, decimals, _timestamp) = _getFeedsById(_feedIds);
        _convertToWei(_values, decimals);
    }

    /**
     * @inheritdoc FtsoV2Interface
     */
    function calculateFeeById(bytes21 _feedId) external view returns (uint256 _fee) {
        // first check for feed id changes
        _feedId = _getCurrentFeedId(_feedId);
        if (_isCustomFeedId(_feedId)) {
            IICustomFeed customFeed = customFeedsData[_feedId].customFeed;
            require(address(customFeed) != address(0), "custom feed id not supported");
            return customFeed.calculateFee();
        } else {
            fastUpdatesConfiguration.getFeedIndex(_feedId); // check if feed id is supported
            bytes21[] memory feedIds = new bytes21[](1);
            feedIds[0] = _feedId;
            return feeCalculator.calculateFeeByIds(feedIds);
        }
    }

    /**
     * @inheritdoc FtsoV2Interface
     */
    function calculateFeeByIds(bytes21[] memory _feedIds) external view returns (uint256 _fee) {
        // first check for feed id changes
        for (uint256 i = 0; i < _feedIds.length; i++) {
            _feedIds[i] = _getCurrentFeedId(_feedIds[i]);
        }
        bytes21[] memory fastUpdateFeedIds = new bytes21[](_getNumberOfFastUpdateFeedIds(_feedIds));
        uint256 index = 0;
        for (uint256 i = 0; i < _feedIds.length; i++) {
            if (_isCustomFeedId(_feedIds[i])) {
                IICustomFeed customFeed = customFeedsData[_feedIds[i]].customFeed;
                require(address(customFeed) != address(0), "custom feed id not supported");
                _fee += customFeed.calculateFee();
            } else {
                fastUpdatesConfiguration.getFeedIndex(_feedIds[i]); // check if feed id is supported
                fastUpdateFeedIds[index] = _feedIds[i];
                index++;
            }
        }
        if (index > 0) {
            _fee += feeCalculator.calculateFeeByIds(fastUpdateFeedIds);
        }
    }

    /////////////////////////////// FEED_INDEX FUNCTIONS ///////////////////////////////

    /**
     * Returns the feed id at a given index. Removed (unused) feed index will return bytes21(0).
     * NOTE: Only works for feed index in the FastUpdatesConfiguration contract.
     * @param _index The index.
     * @return _feedId The feed id.
     */
    function getFeedId(uint256 _index) external view returns (bytes21) {
        return fastUpdatesConfiguration.getFeedId(_index);
    }

    /**
     * Returns the index of a feed id.
     * NOTE: Only works for feed id in the FastUpdatesConfiguration contract.
     * @param _feedId The feed id.
     * @return _index The index of the feed.
     */
    function getFeedIndex(bytes21 _feedId) external view returns (uint256) {
        return fastUpdatesConfiguration.getFeedIndex(_feedId);
    }

    /**
     * Returns stored data of a feed.
     * A fee (calculated by the FeeCalculator contract) may need to be paid.
     * @param _index The index of the feed, corresponding to feed id in
     * the FastUpdatesConfiguration contract.
     * @return _value The value for the requested feed.
     * @return _decimals The decimal places for the requested feed.
     * @return _timestamp The timestamp of the last update.
     */
    function getFeedByIndex(uint256 _index) external payable returns (uint256, int8, uint64) {
        return _getFeedByIndex(_index);
    }

    /**
     * Returns stored data of each feed.
     * A fee (calculated by the FeeCalculator contract) may need to be paid.
     * @param _indices Indices of the feeds, corresponding to feed ids in
     * the FastUpdatesConfiguration contract.
     * @return _values The list of values for the requested feeds.
     * @return _decimals The list of decimal places for the requested feeds.
     * @return _timestamp The timestamp of the last update.
     */
    function getFeedsByIndex(uint256[] memory _indices)
        external payable
        returns (
            uint256[] memory,
            int8[] memory,
            uint64
        )
    {
        return fastUpdater.fetchCurrentFeeds{value: msg.value} (_indices);
    }

    /**
     * Returns value in wei and timestamp of a feed.
     * A fee (calculated by the FeeCalculator contract) may need to be paid.
     * @param _index The index of the feed, corresponding to feed id in
     * the FastUpdatesConfiguration contract.
     * @return _value The value for the requested feed in wei (i.e. with 18 decimal places).
     * @return _timestamp The timestamp of the last update.
     */
    function getFeedByIndexInWei(uint256 _index) external payable
        returns (
            uint256 _value,
            uint64 _timestamp
        )
    {
        int8 decimals;
        (_value, decimals, _timestamp) = _getFeedByIndex(_index);
        _value = _convertToWei(_value, decimals);
    }

    /** Returns value in wei of each feed and a timestamp.
     * For some feeds, a fee (calculated by the FeeCalculator contract) may need to be paid.
     * @param _indices Indices of the feeds, corresponding to feed ids in
     * the FastUpdatesConfiguration contract.
     * @return _values The list of values for the requested feeds in wei (i.e. with 18 decimal places).
     * @return _timestamp The timestamp of the last update.
     */
    function getFeedsByIndexInWei(uint256[] memory _indices)
        external payable
        returns (
            uint256[] memory _values,
            uint64 _timestamp
        )
    {
        int8[] memory decimals;
        (_values, decimals, _timestamp) = fastUpdater.fetchCurrentFeeds{value: msg.value} (_indices);
        _convertToWei(_values, decimals);
    }

    /**
     * Calculates the fee for fetching a feed.
     * @param _index The index of the feed, corresponding to feed id in
     * the FastUpdatesConfiguration contract.
     * @return _fee The fee for fetching the feed.
     */
    function calculateFeeByIndex(uint256 _index) external view returns (uint256 _fee) {
        uint256[] memory indices = new uint256[](1);
        indices[0] = _index;
        return feeCalculator.calculateFeeByIndices(indices);
    }

    /**
     * Calculates the fee for fetching feeds.
     * @param _indices Indices of the feeds, corresponding to feed ids in
     * the FastUpdatesConfiguration contract.
     * @return _fee The fee for fetching the feeds.
     */
    function calculateFeeByIndices(uint256[] memory _indices) external view returns (uint256 _fee) {
        return feeCalculator.calculateFeeByIndices(_indices);
    }

    /////////////////////////////// GOVERNANCE FUNCTIONS ///////////////////////////////

    /**
     * Adds custom feeds. Valid feed categories are 32 (0x20) - 63 (0x3F).
     * @param _customFeeds The custom feeds to add.
     * @dev The feed category is the first byte of the feed id.
     * @dev Only governance can call this method.
     */
    function addCustomFeeds(IICustomFeed[] calldata _customFeeds) external onlyGovernance {
        for (uint256 i = 0; i < _customFeeds.length; i++) {
            bytes21 feedId = _customFeeds[i].feedId();
            require(_isCustomFeedId(feedId), "invalid feed category");
            CustomFeedData storage customFeedData = customFeedsData[feedId];
            require(customFeedData.index == 0, "feed already exists");
            customFeedIds.push(feedId);
            customFeedData.customFeed = _customFeeds[i];
            customFeedData.index = uint96(customFeedIds.length);
            emit CustomFeedAdded(feedId, _customFeeds[i]);
        }
    }

    /**
     * Replaces custom feeds.
     * @param _customFeeds The custom feeds to replace.
     * @dev Only governance can call this method.
     */
    function replaceCustomFeeds(IICustomFeed[] calldata _customFeeds) external onlyGovernance {
        for (uint256 i = 0; i < _customFeeds.length; i++) {
            bytes21 feedId = _customFeeds[i].feedId();
            CustomFeedData storage customFeedData = customFeedsData[feedId];
            require(customFeedData.index != 0, "feed does not exist");
            emit CustomFeedReplaced(feedId, customFeedData.customFeed, _customFeeds[i]);
            customFeedData.customFeed = _customFeeds[i];
        }
    }

    /**
     * Removes custom feeds.
     * @param _feedIds The feed ids to remove.
     * @dev Only governance can call this method.
     */
    function removeCustomFeeds(bytes21[] calldata _feedIds) external onlyGovernance {
        for (uint256 i = 0; i < _feedIds.length; i++) {
            CustomFeedData storage customFeedData = customFeedsData[_feedIds[i]];
            uint96 index = customFeedData.index;
            require(index != 0, "feed does not exist");
            uint256 length = customFeedIds.length; // length >= index > 0
            if (index != length) {
                bytes21 lastFeedId = customFeedIds[length - 1];
                customFeedIds[index - 1] = lastFeedId;
                customFeedsData[lastFeedId].index = index;
            }
            customFeedIds.pop();
            delete customFeedsData[_feedIds[i]];
            emit CustomFeedRemoved(_feedIds[i]);
        }
    }

    /**
     * Change feed ids. This is used when a feed id is updated (e.g. feed renamed).
     * @param _oldFeedIds The old feed ids.
     * @param _newFeedIds The new feed ids.
     * @dev Only governance can call this method.
     */
    function changeFeedIds(bytes21[] calldata _oldFeedIds, bytes21[] calldata _newFeedIds) external onlyGovernance {
        require(_oldFeedIds.length == _newFeedIds.length, "array lengths do not match");
        for (uint256 i = 0; i < _oldFeedIds.length; i++) {
            require(_oldFeedIds[i] != _newFeedIds[i], "feed ids are the same");
            uint88 index = feedIdChanges[_oldFeedIds[i]].index;
            if (_newFeedIds[i] == bytes21(0)) { // remove feed id change
                if (index != 0) {
                    uint256 length = changedFeedIds.length; // length >= index > 0
                    if (index != length) {
                        bytes21 lastFeedId = changedFeedIds[length - 1];
                        feedIdChanges[lastFeedId].index = index;
                        changedFeedIds[index - 1] = lastFeedId;
                    }
                    changedFeedIds.pop();
                    delete feedIdChanges[_oldFeedIds[i]];
                } else {
                    revert("feed id change does not exist");
                }
            } else {
                if (index == 0) { // add feed id change
                    changedFeedIds.push(_oldFeedIds[i]);
                    feedIdChanges[_oldFeedIds[i]] = FeedIdChange(_newFeedIds[i], uint88(changedFeedIds.length));
                } else { // update feed id change
                    feedIdChanges[_oldFeedIds[i]].newFeedId = _newFeedIds[i];
                }
            }
            emit FeedIdChanged(_oldFeedIds[i], _newFeedIds[i]);
        }
    }

    /**
     * Returns the contract used with custom feed or address zero if feed id is not supported.
     * @param _feedId The feed id.
     * @return _customFeed The custom feed contract.
     */
    function getCustomFeedContract(bytes21 _feedId) external view returns (IICustomFeed _customFeed) {
        return customFeedsData[_feedId].customFeed;
    }

    /**
     * Returns the custom feed ids.
     */
    function getCustomFeedIds() external view returns (bytes21[] memory) {
        return customFeedIds;
    }

    /**
     * Returns the feed id change or bytes21(0) if feed id is not changed.
     * @param _oldFeedId The old feed id.
     * @return _newFeedId The new feed id.
     */
    function getFeedIdChange(bytes21 _oldFeedId) external view returns (bytes21 _newFeedId) {
        return feedIdChanges[_oldFeedId].newFeedId;
    }

    /**
     * Returns the changed feed ids.
     */
    function getChangedFeedIds() external view returns (bytes21[] memory) {
        return changedFeedIds;
    }

    /////////////////////////////// UUPS UPGRADABLE ///////////////////////////////

    /**
     * @inheritdoc UUPSUpgradeable
     * @dev Only governance can call this method.
     */
    function upgradeToAndCall(address newImplementation, bytes memory data)
        public payable override
        onlyGovernance
        onlyProxy
    {
        super.upgradeToAndCall(newImplementation, data);
    }

    function implementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    /**
     * Unused. just to present to satisfy UUPSUpgradeable requirement.
     * The real check is in onlyGovernance modifier on upgradeTo and upgradeToAndCall.
     */
    function _authorizeUpgrade(address newImplementation) internal override {}

    /////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////////

    // Valid categories are 32 (0x20) - 63 (0x3F).
    function _isCustomFeedId(bytes21 _feedId) internal pure returns (bool) {
        uint8 category = uint8(bytes1(_feedId[0]));
        return 32 <= category && category < 64;
    }

    // Returns the number of fast update feed ids in the list.
    function _getNumberOfFastUpdateFeedIds(bytes21[] memory _feedIds)
        internal pure
        returns (uint256 _numberOfFastUpdateFeedIds)
    {
        for (uint256 i = 0; i < _feedIds.length; i++) {
            if (!_isCustomFeedId(_feedIds[i])) {
                _numberOfFastUpdateFeedIds++;
            }
        }
    }

    // Returns the indices of the fast update feeds - all that are not custom feeds
    function _getFastUpdateIndices(bytes21[] memory _feedIds)
        internal view
        returns (uint256[] memory _fastUpdateIndices)
    {
        uint256 length = _feedIds.length;
        uint256 count = _getNumberOfFastUpdateFeedIds(_feedIds);
        _fastUpdateIndices = new uint256[](count);
        while (count > 0) {
            length--;
            if (!_isCustomFeedId(_feedIds[length])) {
                count--;
                _fastUpdateIndices[count] = fastUpdatesConfiguration.getFeedIndex(_feedIds[length]);
            }
        }
    }

    // Returns the feed data for all feed ids.
    // NOTE: _timestamp is the same for all feeds (this is not checked), but even if custom feeds are included,
    // we as well get the referenced feeds values from the FastUpdater contract which will return the same timestamp.
    function _getFeedsById(bytes21[] memory _feedIds)
        internal
        returns(
            uint256[] memory _values,
            int8[] memory _decimals,
            uint64 _timestamp
        )
    {
        // first check for feed id changes
        for (uint256 i = 0; i < _feedIds.length; i++) {
            _feedIds[i] = _getCurrentFeedId(_feedIds[i]);
        }
        uint256[] memory indices = _getFastUpdateIndices(_feedIds);
        if (_feedIds.length == indices.length) { // all feeds are fast update feeds
            return fastUpdater.fetchCurrentFeeds{value: msg.value} (indices);
        } else {
            _values = new uint256[](_feedIds.length);
            _decimals = new int8[](_feedIds.length);
            // set custom feeds data first
            for (uint256 i = 0; i < _feedIds.length; i++) {
                if (_isCustomFeedId(_feedIds[i])) {
                    IICustomFeed customFeed = customFeedsData[_feedIds[i]].customFeed;
                    require(address(customFeed) != address(0), "custom feed id not supported");
                    uint256 fee = customFeed.calculateFee();
                    (_values[i], _decimals[i], _timestamp) = customFeed.getCurrentFeed{value: fee} ();
                }
            }
            if (indices.length > 0) {
                uint256[] memory values;
                int8[] memory decimals;
                // set fast update feeds data - use all remaining balance for fees
                //slither-disable-next-line arbitrary-send-eth
                (values, decimals, _timestamp) = fastUpdater.fetchCurrentFeeds{value: address(this).balance} (indices);
                uint256 index = 0;
                for (uint256 i = 0; i < _feedIds.length; i++) {
                    if (!_isCustomFeedId(_feedIds[i])) {
                        _values[i] = values[index];
                        _decimals[i] = decimals[index];
                        index++;
                    }
                }
            }
        }
    }

    // Returns the feed data for a feed id.
    function _getFeedById(bytes21 _feedId)
        internal
        returns(
            uint256,
            int8,
            uint64
        )
    {
        // first check for feed id changes
        _feedId = _getCurrentFeedId(_feedId);
        if (_isCustomFeedId(_feedId)) {
            IICustomFeed customFeed = customFeedsData[_feedId].customFeed;
            require(address(customFeed) != address(0), "custom feed id not supported");
            return customFeed.getCurrentFeed{value: msg.value} ();
        } else {
            return _getFeedByIndex(fastUpdatesConfiguration.getFeedIndex(_feedId));
        }
    }

    // Returns the feed data for a feed index.
    function _getFeedByIndex(uint256 _index)
        internal
        returns (
            uint256,
            int8,
            uint64
        )
    {
        uint256[] memory indices = new uint256[](1);
        indices[0] = _index;
        (uint256[] memory values, int8[] memory decimals, uint64 timestamp) =
            fastUpdater.fetchCurrentFeeds{value: msg.value} (indices);
        return (values[0], decimals[0], timestamp);
    }

    // Returns the current feed id if it has been changed.
    function _getCurrentFeedId(bytes21 _feedId)
        internal view
        returns (bytes21)
    {
        bytes21 updatedFeedId = feedIdChanges[_feedId].newFeedId;
        if (updatedFeedId != bytes21(0)) {
            return updatedFeedId;
        } else {
            return _feedId;
        }
    }

    // Converts values to wei - updates _values in place.
    function _convertToWei(uint256[] memory _values, int8[] memory _decimals)
        internal pure
    {
        assert(_values.length == _decimals.length);
        for (uint256 i = 0; i < _values.length; i++) {
            _values[i] = _convertToWei(_values[i], _decimals[i]);
        }
    }

    // Converts a value to wei.
    function _convertToWei(uint256 _value, int8 _decimals)
        internal pure
        returns (uint256)
    {
        int256 decimalsDiff = 18 - _decimals;
        // value in wei (18 decimals)
        if (decimalsDiff < 0) {
            return _value / (10 ** uint256(-decimalsDiff));
        } else {
            return _value * (10 ** uint256(decimalsDiff));
        }
    }

    /**
     * Implementation of the AddressUpdatable abstract method.
     */
    function _updateContractAddresses(
        bytes32[] memory _contractNameHashes,
        address[] memory _contractAddresses
    )
        internal override
    {
        fastUpdater = IFastUpdater(
            _getContractAddress(_contractNameHashes, _contractAddresses, "FastUpdater"));
        fastUpdatesConfiguration = IFastUpdatesConfiguration(
            _getContractAddress(_contractNameHashes, _contractAddresses, "FastUpdatesConfiguration"));
        feeCalculator = IFeeCalculator(
            _getContractAddress(_contractNameHashes, _contractAddresses, "FeeCalculator"));
        relay = IRelay(_getContractAddress(_contractNameHashes, _contractAddresses, "Relay"));
    }
}