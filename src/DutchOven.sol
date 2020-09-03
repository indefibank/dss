// Copyright (C) 2020 Maker Ecosystem Growth Holdings, INC.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.5.12;

contract VatLike {
    function move(address,address,uint) external;
    function flux(bytes32,address,address,uint) external;
}

contract PipLike {
    function peek() external returns (bytes32, bool);
}

contract SpotLike {
    function par() public returns (uint256);
    function ilks(bytes32) public returns (PipLike, uint256);
}

contract DogLike {
    function digs(uint) external;
}

contract OvenCallee {
    function ovenCall(uint256, uint256, bytes calldata) external;
}

contract Abacus {
    function price(uint256, uint256) external view returns (uint256);
}

contract Oven {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) external /* note */ auth { wards[usr] = 1; }
    function deny(address usr) external /* note */ auth { wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "Oven/not-authorized");
        _;
    }

    // --- Data ---
    bytes32  public ilk;   // Collateral type of this Oven

    address  public vow;   // Recipient of dai raised in auctions
    VatLike  public vat;   // Core CDP Engine
    DogLike  public dog;   // Dog liquidation module
    SpotLike public spot;  // Spotter
    Abacus   public calc;  // Helper contract to calculate current price of an auction
    uint256  public buf;   // Multiplicative factor to increase starting price    [ray]
    uint256  public dust;  // Minimum tab in an auction; read from Vat instead??? [rad]
    uint256  public step;  // Length of time between price drops                  [seconds]
    uint256  public cut;   // Per-step multiplicative decrease in price           [ray]
    uint256  public tail;  // Time elapsed before auction reset                   [seconds]
    uint256  public cusp;  // Percentage drop before auction reset                [ray]
    uint256  public bakes; // Bake count

    struct Loaf {
        uint256 tab;  // Dai to raise       [rad]
        uint256 lot;  // ETH to sell        [wad]
        address usr;  // Liquidated CDP
        uint96  tic;  // Auction start time
        uint256 top;  // Starting price     [ray]
    }
    mapping(uint256 => Loaf) public loaves;

    uint256 internal locked;

    // --- Events ---
    event Bake(
        uint256  id,
        uint256 tab,
        uint256 lot,
        address indexed usr
    );

    event Warm(
        uint256  id,
        uint256 tab,
        uint256 lot,
        address indexed usr
    );

    // --- Init ---
    constructor(address vat_, address dog_, bytes32 ilk_) public {
        vat = VatLike(vat_);
        dog = DogLike(dog_);
        ilk = ilk_;
        cut = RAY;
        step = 1;
        wards[msg.sender] = 1;
    }

    modifier lock {
        require(locked == 0, "Oven/system-locked");
        locked = 1;
        _;
        locked = 0;
    }

    // --- Administration ---
    function file(bytes32 what, uint256 data) external {
        if      (what ==  "cut") require((cut = data) <= RAY, "Oven/cut-gt-RAY");
        else if (what ==  "buf") buf  = data;
        else if (what == "step") step = data;
        else if (what == "dust") dust = data;
        else if (what == "tail") tail = data; // Time elapsed    before auction reset
        else if (what == "cusp") cusp = data; // Percentage drop before auction reset
        else revert("Oven/file-unrecognized-param");
    }
    function file(bytes32 what, address data) external auth {
        if      (what ==  "dog") dog  = DogLike(data);
        else if (what ==  "vow") vow  = data;
        else if (what == "calc") calc = Abacus(data);
        else revert("Oven/file-unrecognized-param");
    }

    // --- Math ---
    uint256 constant RAY = 10 ** 27;
    uint256 constant BLN = 10 ** 9;

    function min(uint x, uint y) internal pure returns (uint z) {
        return x <= y ? x : y;
    }
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function rmul(uint x, uint y) internal pure returns (uint z) {
        z = mul(x, y) / RAY;
    }
    function rdiv(uint x, uint y) internal pure returns (uint z) {
        z = mul(x, RAY) / y;
    }
    // Optimized version from dss PR #78
    function rpow(uint x, uint n, uint b) internal pure returns (uint z) {
        assembly {
            switch n case 0 { z := b }
            default {
                switch x case 0 { z := 0 }
                default {
                    switch mod(n, 2) case 0 { z := b } default { z := x }
                    let half := div(b, 2)  // for rounding.
                    for { n := div(n, 2) } n { n := div(n,2) } {
                        let xx := mul(x, x)
                        if shr(128, x) { revert(0,0) }
                        let xxRound := add(xx, half)
                        if lt(xxRound, xx) { revert(0,0) }
                        x := div(xxRound, b)
                        if mod(n,2) {
                            let zx := mul(z, x)
                            if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                            let zxRound := add(zx, half)
                            if lt(zxRound, zx) { revert(0,0) }
                            z := div(zxRound, b)
                        }
                    }
                }
            }
        }
    }

    // --- Auction ---

    // start an auction
    function bake(uint256 tab,  // debt             [rad]
                  uint256 lot,  // collateral       [wad]
                  address usr   // liquidated vault
    ) external auth returns (uint256 id) {
        require(bakes < uint(-1), "Oven/overflow");
        id = ++bakes;

        // Caller must hope on the Oven
        vat.flux(ilk, msg.sender, address(this), lot);

        loaves[id].tab = tab;
        loaves[id].lot = lot;
        loaves[id].usr = usr;
        loaves[id].tic = uint96(now);

        // Could get this from rmul(Vat.ilks(ilk).spot, Spotter.mat()) instead,
        // but if mat has changed since the last poke, the resulting value will
        // be incorrect.
        (PipLike pip, ) = spot.ilks(ilk);
        (bytes32 val, bool has) = pip.peek();
        require(has, "Oven/invalid-price");
        loaves[id].top = rmul(rdiv(mul(uint256(val), BLN), spot.par()), buf);

        emit Bake(id, tab, lot, usr);
    }

    // Reset an auction
    function warm(uint256 id) external { 
        // Read auction data
        Loaf memory loaf = loaves[id];
        require(loaf.tab > 0, "Oven/not-running-auction");

        // Compute current price [ray]
        uint256 pay = calc.price(loaf.top, loaf.tic);

        // Check that auction needs reset
        require(sub(now, loaf.tic) > tail || rdiv(pay, loaf.top) < cusp, "Oven/cannot-reset");
        
        loaves[id].tic = uint96(now);

        // Could get this from rmul(Vat.ilks(ilk).spot, Spotter.mat()) instead, but if mat has changed since the
        // last poke, the resulting value will be incorrect
        (PipLike pip, ) = spot.ilks(ilk);
        (bytes32 val, bool has) = pip.peek();
        require(has, "Oven/invalid-price");
        loaves[id].top = rmul(rdiv(mul(uint256(val), 10 ** 9), spot.par()), buf);

        emit Warm(id, loaves[id].tab, loaves[id].lot, loaves[id].usr);
    }

    // Buy amt of collateral from auction indexed by id
    // TODO: Evaluate usage of `max` and `pay` variables.
    //       Consider using `pay` and `min`.
    function take(uint256 id,           // auction id
                  uint256 amt,          // upper limit on amount of collateral to buy       [wad]
                  uint256 max,          // maximum acceptable price (DAI / ETH)             [ray]
                  address who,          // who will receive the collateral and pay the debt
                  bytes calldata data   //
    ) external lock {
        // Read auction data
        Loaf memory loaf = loaves[id];
        require(loaf.tab > 0, "Oven/not-running-auction");

        // Compute current price [ray]
        uint256 pay = calc.price(loaf.top, loaf.tic);

        // Check that auction doesn't need reset
        require(sub(now, loaf.tic) <= tail && rdiv(pay, loaf.top) >= cusp, "Oven/needs-reset");

        // Ensure price is acceptable to buyer
        require(pay <= max, "Oven/too-expensive");

        // Purchase as much as possible, up to amt
        uint256 slice = min(loaf.lot, amt);

        // DAI needed to buy a slice of this loaf
        uint256 owe = mul(slice, max);

        // Don't collect more than tab of DAI
        if (owe > loaf.tab) {
            owe = loaf.tab;

            // Readjust slice
            slice = owe / max;
        }

        // Calculate remaining tab after operation
        loaf.tab = sub(loaf.tab, owe);
        require(loaf.tab == 0 || loaf.tab >= dust, "Oven/dust");

        // Calculate remaining lot after operation
        loaf.lot = sub(loaf.lot, slice);
        // Send collateral to who
        vat.flux(ilk, address(this), who, slice);

        // Do external call (if defined)
        if (data.length > 0) {
            OvenCallee(who).ovenCall(owe, slice, data);
        }

        // Get DAI from who address
        vat.move(who, vow, owe);

        // give the dog a bone: removes Dai out for liquidation from accumulator
        dog.digs(owe);

        if (loaf.lot == 0) {
            delete loaves[id];
        } else if (loaf.tab == 0) {
            // Should we return collateral incrementally instead?
            vat.flux(ilk, address(this), loaf.usr, loaf.lot);
            delete loaves[id];
        } else {
            loaves[id].tab = loaf.tab;
            loaves[id].lot = loaf.lot;
        }

        // Emit event?
    }

    // --- Shutdown ---

    // Cancel an auction during ES
    function yank() external auth {
        // TODO
    }
}
