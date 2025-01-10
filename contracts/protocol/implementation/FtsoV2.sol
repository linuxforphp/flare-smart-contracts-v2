// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../../userInterfaces/LTS/FtsoV2Interface.sol";
import "../../userInterfaces/IFastUpdater.sol";
import "../../userInterfaces/IFastUpdatesConfiguration.sol";
import "../../userInterfaces/IFeeCalculator.sol";
import "../../userInterfaces/IRelay.sol";
import "../../governance/implementation/Governed.sol";
import "../../utils/implementation/AddressUpdatable.sol";
import "../../utils/lib/AddressSet.sol";
import "../../ftso/interface/IICalculatedFeed.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract FtsoV2 is FtsoV2Interface, Governed, AddressUpdatable {
    using MerkleProof for bytes32[];
    using AddressSet for AddressSet.State;

    struct CalculatedFeedData {
        IICalculatedFeed calculatedFeed;
        uint96 index;  // index is 1-based, 0 means non-existent
    }

    IFastUpdater public fastUpdater;
    IFastUpdatesConfiguration public fastUpdatesConfiguration;
    IFeeCalculator public feeCalculator;
    IRelay public relay;

    bytes21[] public calculatedFeedIds;
    mapping(bytes21 feedId => CalculatedFeedData) private calculatedFeedsData;

    uint256 public constant FTSO_PROTOCOL_ID = 100;

    /**
     * Constructor.
     * @param _governanceSettings The address of the GovernanceSettings contract.
     * @param _initialGovernance The initial governance address.
     * @param _addressUpdater The address of the AddressUpdater contract.
     */
    constructor(
        IGovernanceSettings _governanceSettings,
        address _initialGovernance,
        address _addressUpdater
    )
        Governed(_governanceSettings, _initialGovernance) AddressUpdatable(_addressUpdater)
    { }

    /**
     * @inheritdoc FtsoV2Interface
     */
    function getSupportedFeedIds() external view returns (bytes21[] memory _feedIds) {
        bytes21[] memory fastUpdateFeedIds = fastUpdatesConfiguration.getFeedIds();
        uint256 unusedIndicesLength = fastUpdatesConfiguration.getUnusedIndices().length;
        // unusedIndicesLength is less than or equal to fastUpdateFeedIds.length
        _feedIds = new bytes21[](calculatedFeedIds.length + fastUpdateFeedIds.length - unusedIndicesLength);
        uint256 index = 0;
        // add fast update feed ids if not removed
        for (uint256 i = 0; i < fastUpdateFeedIds.length; i++) {
            if (fastUpdateFeedIds[i] != bytes21(0)) {
                _feedIds[index] = fastUpdateFeedIds[i];
                index++;
            }
        }
        // add calculated feed ids
        for (uint256 i = 0; i < calculatedFeedIds.length; i++) {
            _feedIds[index] = calculatedFeedIds[i];
            index++;
        }
    }

    /**
     * Returns the feed id at a given index. Removed (unused) feed index will return bytes21(0).
     * @param _index The index.
     * @return _feedId The feed id.
     */
    function getFeedId(uint256 _index) external view returns (bytes21) {
        return fastUpdatesConfiguration.getFeedId(_index);
    }

    /**
     * Returns the index of a feed.
     * @param _feedId The feed id.
     * @return _index The index of the feed.
     */
    function getFeedIndex(bytes21 _feedId) external view returns (uint256) {
        return fastUpdatesConfiguration.getFeedIndex(_feedId);
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
     * @inheritdoc FtsoV2Interface
     */
    function getFeedById(bytes21 _feedId) external payable returns (uint256, int8, uint64) {
        return _getFeedById(_feedId);
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
    function getFeedsByIndex(uint256[] calldata _indices)
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
     * @inheritdoc FtsoV2Interface
     */
    function getFeedsById(bytes21[] calldata _feedIds)
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

    /** Returns value in wei of each feed and a timestamp.
     * For some feeds, a fee (calculated by the FeeCalculator contract) may need to be paid.
     * @param _indices Indices of the feeds, corresponding to feed ids in
     * the FastUpdatesConfiguration contract.
     * @return _values The list of values for the requested feeds in wei (i.e. with 18 decimal places).
     * @return _timestamp The timestamp of the last update.
     */
    function getFeedsByIndexInWei(uint256[] calldata _indices)
        external payable
        returns (
            uint256[] memory _values,
            uint64 _timestamp
        )
    {
        int8[] memory decimals;
        (_values, decimals, _timestamp) = fastUpdater.fetchCurrentFeeds{value: msg.value} (_indices);
        _values = _convertToWei(_values, decimals);
    }

    /**
     * @inheritdoc FtsoV2Interface
     */
    function getFeedsByIdInWei(bytes21[] calldata _feedIds)
        external payable
        returns (
            uint256[] memory _values,
            uint64 _timestamp
        )
    {
        int8[] memory decimals;
        (_values, decimals, _timestamp) = _getFeedsById(_feedIds);
        _values = _convertToWei(_values, decimals);
    }

    /**
     * @inheritdoc FtsoV2Interface
     */
    function calculateGetFeedFee(bytes21 _feedId) external view returns (uint256 _fee) {
        if (_isCalculatedFeedId(_feedId)) {
            IICalculatedFeed calculatedFeed = calculatedFeedsData[_feedId].calculatedFeed;
            require(address(calculatedFeed) != address(0), "calculated feed id not supported");
            return calculatedFeed.calculateFee();
        } else {
            bytes21[] memory feedIds = new bytes21[](1);
            feedIds[0] = _feedId;
            return feeCalculator.calculateFeeByIds(feedIds);
        }
    }

    /**
     * @inheritdoc FtsoV2Interface
     */
    function calculateGetFeedsFee(bytes21[] calldata _feedIds) external view returns (uint256 _fee) {
        uint256 count = _getNumberOfFastUpdateFeedIds(_feedIds);
        if (count == _feedIds.length) {
            return feeCalculator.calculateFeeByIds(_feedIds);
        } else {
            bytes21[] memory fastUpdateFeedIds = new bytes21[](count);
            count = 0;
            for (uint256 i = 0; i < _feedIds.length; i++) {
                if (_isCalculatedFeedId(_feedIds[i])) {
                    IICalculatedFeed calculatedFeed = calculatedFeedsData[_feedIds[i]].calculatedFeed;
                    require(address(calculatedFeed) != address(0), "calculated feed id not supported");
                    _fee += calculatedFeed.calculateFee();
                } else {
                    fastUpdateFeedIds[count] = _feedIds[i];
                    count++;
                }
            }
            _fee += feeCalculator.calculateFeeByIds(fastUpdateFeedIds);
        }
    }

    /**
     * Returns the contract used with calculated feed or address zero if feed id is not supported.
     */
    function getCalculatedFeedContract(bytes21 _feedId) external view returns (IICalculatedFeed _calculatedFeed) {
        return calculatedFeedsData[_feedId].calculatedFeed;
    }

    /////////////////////////////// GOVERNANCE FUNCTIONS ///////////////////////////////

    /**
     * Adds calculated feeds. Valid feed categories are 32 (0x20) - 63 (0x3F).
     * @param _calculatedFeeds The calculated feeds to add.
     * @dev The feed category is the first byte of the feed id.
     * @dev Only governance can call this method.
     */
    function addCalculatedFeeds(IICalculatedFeed[] calldata _calculatedFeeds) external onlyGovernance {
        for (uint256 i = 0; i < _calculatedFeeds.length; i++) {
            bytes21 feedId = _calculatedFeeds[i].feedId();
            require(_isCalculatedFeedId(feedId), "invalid feed category");
            CalculatedFeedData storage calculatedFeedData = calculatedFeedsData[feedId];
            require(calculatedFeedData.index == 0, "feed already exists");
            calculatedFeedIds.push(feedId);
            calculatedFeedData.calculatedFeed = _calculatedFeeds[i];
            calculatedFeedData.index = uint96(calculatedFeedIds.length);
        }
    }

    /**
     * Replaces calculated feeds.
     * @param _calculatedFeeds The calculated feeds to replace.
     * @dev Only governance can call this method.
     */
    function replaceCalculatedFeeds(IICalculatedFeed[] calldata _calculatedFeeds) external onlyGovernance {
        for (uint256 i = 0; i < _calculatedFeeds.length; i++) {
            bytes21 feedId = _calculatedFeeds[i].feedId();
            CalculatedFeedData storage calculatedFeedData = calculatedFeedsData[feedId];
            require(calculatedFeedData.index != 0, "feed does not exist");
            calculatedFeedData.calculatedFeed = _calculatedFeeds[i];
        }
    }

    /**
     * Removes calculated feeds.
     * @param _feedIds The feed ids to remove.
     * @dev Only governance can call this method.
     */
    function removeCalculatedFeeds(bytes21[] calldata _feedIds) external onlyGovernance {
        for (uint256 i = 0; i < _feedIds.length; i++) {
            CalculatedFeedData storage calculatedFeedData = calculatedFeedsData[_feedIds[i]];
            require(calculatedFeedData.index != 0, "feed does not exist");
            uint96 index = calculatedFeedData.index - 1;
            if (calculatedFeedIds.length > 1) {
                calculatedFeedIds[index] = calculatedFeedIds[calculatedFeedIds.length - 1];
                calculatedFeedsData[calculatedFeedIds[index]].index = index + 1;
            }
            calculatedFeedIds.pop();
            delete calculatedFeedsData[_feedIds[i]];
        }
    }

    /////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////////

    // Valid categories are 32 (0x20) - 63 (0x3F).
    function _isCalculatedFeedId(bytes21 _feedId) internal pure returns (bool) {
        uint8 category = uint8(bytes1(_feedId[0]));
        return 32 <= category && category < 64;
    }

    // Returns the number of fast update feed ids in the list.
    function _getNumberOfFastUpdateFeedIds(bytes21[] calldata _feedIds)
        internal pure
        returns (uint256 _numberOfFastUpdateFeedIds)
    {
        for (uint256 i = 0; i < _feedIds.length; i++) {
            if (!_isCalculatedFeedId(_feedIds[i])) {
                _numberOfFastUpdateFeedIds++;
            }
        }
    }

    // Returns the indices of the fast update feeds - all that are not calculated feeds
    function _getFastUpdateIndices(bytes21[] calldata _feedIds)
        internal view
        returns (uint256[] memory _fastUpdateIndices)
    {
        uint256 length = _feedIds.length;
        uint256 count = _getNumberOfFastUpdateFeedIds(_feedIds);
        _fastUpdateIndices = new uint256[](count);
        while (count > 0) {
            length--;
            if (!_isCalculatedFeedId(_feedIds[length])) {
                count--;
                _fastUpdateIndices[count] = fastUpdatesConfiguration.getFeedIndex(_feedIds[length]);
            }
        }
    }

    // Returns the feed ids of the fast update feeds - all that are not calculated feeds
    function _getFastUpdateFeedIds(bytes21[] calldata _feedIds)
        internal pure
        returns (bytes21[] memory _fastUpdateFeedIds)
    {
        uint256 length = _feedIds.length;
        uint256 count = _getNumberOfFastUpdateFeedIds(_feedIds);
        if (count == length) {
            return _feedIds;
        }
        _fastUpdateFeedIds = new bytes21[](count);
        while (count > 0) {
            length--;
            if (!_isCalculatedFeedId(_feedIds[length])) {
                count--;
                _fastUpdateFeedIds[count] = _feedIds[length];
            }
        }
    }

    function _getFeedsById(bytes21[] calldata _feedIds)
        internal
        returns(
            uint256[] memory _values,
            int8[] memory _decimals,
            uint64 _timestamp
        )
    {
        uint256[] memory indices = _getFastUpdateIndices(_feedIds);
        if (_feedIds.length == indices.length) { // all feeds are fast update feeds
            return fastUpdater.fetchCurrentFeeds{value: msg.value} (indices);
        } else {
            _values = new uint256[](_feedIds.length);
            _decimals = new int8[](_feedIds.length);
            // set calculated feeds data first
            for (uint256 i = 0; i < _feedIds.length; i++) {
                if (_isCalculatedFeedId(_feedIds[i])) {
                    IICalculatedFeed calculatedFeed = calculatedFeedsData[_feedIds[i]].calculatedFeed;
                    require(address(calculatedFeed) != address(0), "calculated feed id not supported");
                    uint256 fee = calculatedFeed.calculateFee();
                    (_values[i], _decimals[i], _timestamp) = calculatedFeed.getCurrentFeed{value: fee} ();
                }
            }
            uint256[] memory values;
            int8[] memory decimals;
            // set fast update feeds data - use all remaining balance for fees
            (values, decimals, _timestamp) = fastUpdater.fetchCurrentFeeds{value: address(this).balance} (indices);
            uint256 index = 0;
            for (uint256 i = 0; i < _feedIds.length; i++) {
                if (!_isCalculatedFeedId(_feedIds[i])) {
                    _values[i] = values[index];
                    _decimals[i] = decimals[index];
                    index++;
                }
            }
        }
    }

    function _getFeedById(bytes21 _feedId)
        internal
        returns(
            uint256,
            int8,
            uint64
        )
    {
        if (_isCalculatedFeedId(_feedId)) {
            IICalculatedFeed calculatedFeed = calculatedFeedsData[_feedId].calculatedFeed;
            require(address(calculatedFeed) != address(0), "calculated feed id not supported");
            return calculatedFeed.getCurrentFeed{value: msg.value} ();
        } else {
            return _getFeedByIndex(fastUpdatesConfiguration.getFeedIndex(_feedId));
        }
    }

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


    function _convertToWei(uint256[] memory _values, int8[] memory _decimals)
        internal pure
        returns (
            uint256[] memory
        )
    {
        assert(_values.length == _decimals.length);
        for (uint256 i = 0; i < _values.length; i++) {
            _values[i] = _convertToWei(_values[i], _decimals[i]);
        }
        return _values;
    }

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