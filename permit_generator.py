from typing import Tuple
import web3
from eth_account.signers.base import BaseAccount
from eth_account.messages import encode_structured_data


def int_to_bytes32(value: int) -> str:
    hex_data = hex(value)
    res = hex_data.lstrip("0x")
    zero_count = 64 - len(res)

    if zero_count >= 0:
        return "0x" + "0" * zero_count + res
    else:
        raise


PK = "0xb43b11ebe0523b0c7dc1ef3ef37cc1ce1924fbdbd3bbfcd615dbef5d52ab6fb7"


DOMAIN = {
        "name": "Stablecoin",
        "version": "1",
        "chainId": 99,
        "verifyingContract": "0x11Ee1eeF5D446D07Cf26941C7F2B4B1Dfb9D030B"
    }

ACCOUNT: BaseAccount = web3.Web3().eth.account.from_key(PK)


def generate_data_for_permit(
        account: BaseAccount, *, spender: str, nonce: int, expire: int, allowed: bool) -> Tuple[str, str, int]:
    message = {
        "holder": account.address,
        "spender": web3.Web3.toChecksumAddress(spender),
        "nonce": nonce,
        "expiry": expire,
        "allowed": allowed
    }

    data = {
        "types": {
            "EIP712Domain": [
                {
                    "name": "name",
                    "type": "string"
                },
                {
                    "name": "version",
                    "type": "string"
                },
                {
                    "name": "chainId",
                    "type": "uint256"
                },
                {
                    "name": "verifyingContract",
                    "type": "address"
                }
            ],
            "Permit": [
                {
                    "name": "holder",
                    "type": "address"
                },
                {
                    "name": "spender",
                    "type": "address"
                },
                {
                    "name": "nonce",
                    "type": "uint256"
                },
                {
                    "name": "expiry",
                    "type": "uint256"
                },
                {
                    "name": "allowed",
                    "type": "bool"
                }
            ]
        },
        "primaryType": "Permit",
        "domain": DOMAIN,
        "message": message
    }

    msg = encode_structured_data(data)
    msg_sign = ACCOUNT.sign_message(signable_message=msg)

    return int_to_bytes32(msg_sign['r']), int_to_bytes32(msg_sign['s']), msg_sign['v']


if __name__ == '__main__':

    print(
        generate_data_for_permit(
            ACCOUNT,
            spender="0xdd2d5D3f7f1b35b7A0601D6A00DbB7D44Af58479",
            nonce=0,
            expire=0,
            allowed=True
        )
    )

    print(
        generate_data_for_permit(
            ACCOUNT,
            spender="0xdd2d5D3f7f1b35b7A0601D6A00DbB7D44Af58479",
            nonce=0,
            expire=604414800,
            allowed=True
        )
    )
