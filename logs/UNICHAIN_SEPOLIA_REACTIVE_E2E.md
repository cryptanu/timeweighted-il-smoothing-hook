# Unichain Sepolia + Reactive Lasna E2E

Run date: 2026-06-08

## Contracts

- Hook: `0x351Ef540C185454d80E0b34b97af30876b194640`
- Demo reserve token: `0x40B22B4540B7914B1E7a01faA78E57ac768d6382`
- v4 PoolManager: `0x00B036B58a818B1BC34d502D3fE730Db729e62AC`
- Real v4 pool ID: `0x3e573b701a437ab4b1aec3a94aaea3d74fa8e96a86947313024032dea757521d`
- Reactive Lasna RSC: `0x4C9e691d2e856C34ac7a02EF3568e1D83B3A8bCD`
- Unichain Sepolia callback proxy: `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`
- RVM sender encoded in callback payload: `0x4b992F2Fbf714C0fCBb23baC5130Ace48CaD00cd`
- Settlement topic0: `0xbcbeff20c5c5f2717bc9ac80cd59796fabc4cdfbd7142aee903da540dd02bdba`

## Deployment Transactions

1. Demo reserve token deploy: https://sepolia.uniscan.xyz/tx/0x7e4aa7d9e1b67107ab3659415781e22e4353093c1ea1dc72829efe48a4b2ec25
2. Demo token mint: https://sepolia.uniscan.xyz/tx/0x4913e1ba12668b76bca3f37453528a6f6e200b3133440a12869caf20c4e322a3
3. Reactive-capable hook deploy: https://sepolia.uniscan.xyz/tx/0x6820e3e4bb00e097dd7afdf23405ab046029d749e4555a8808a2173d985d990e
4. v4 pool initialize: https://sepolia.uniscan.xyz/tx/0x9707228702713d50dc0d623140776cc8694b4bf425f40153080107e12d780ab5
5. Lasna RSC deploy: https://lasna.reactscan.net/tx/0x33ec3e372d728decc67bebace03dea45a0a8ce9b1a485e46cfb3feae42c54881
6. RSC fund: https://lasna.reactscan.net/tx/0x10cc3e1008a40ea0ad97d5358fd4d1509bfaa76b2bc824530fc645e63d4636b5
7. Explicit subscription: https://lasna.reactscan.net/tx/0xbb3798e0069e612f43806fd321256b949d1a2035abd818e18f633c327084c7f5

## Subscription Proof

`rnk_getFilters` returned an active filter:

```json
{
  "ChainId": 1301,
  "Contract": "0x351ef540c185454d80e0b34b97af30876b194640",
  "Topics": [
    "0xbcbeff20c5c5f2717bc9ac80cd59796fabc4cdfbd7142aee903da540dd02bdba",
    "0x3e573b701a437ab4b1aec3a94aaea3d74fa8e96a86947313024032dea757521d",
    null,
    null
  ],
  "Configs": [
    {
      "Contract": "0x4c9e691d2e856c34ac7a02ef3568e1d83b3a8bcd",
      "RvmId": "0x4b992f2fbf714c0fcbb23bac5130ace48cad00cd",
      "Active": true
    }
  ]
}
```

## Origin Phase

1. Configure hook Reactive auth: https://sepolia.uniscan.xyz/tx/0x91b79b6eaa7d9273faf24261a813a2657281cba902897feb21d2ef15746634c5
2. Approve reserve token: https://sepolia.uniscan.xyz/tx/0x54d33f6ab17ca620e3d1f453fd6818627915fcc3e03bf0b4cf98e310b52850d2
3. Fund reserve with 10,000 token0: https://sepolia.uniscan.xyz/tx/0x0b6490cc4b21ee00df707093d6fd055d76e71a69a1b47be728900aff2817bdff
4. Record Tier 3 demo LP position: https://sepolia.uniscan.xyz/tx/0x1f8b7eff2ed160c68683376a8701deaf07e3299ad08ca99e1a8547f25de86270
5. Emit `ReactiveSettlementRequested`: https://sepolia.uniscan.xyz/tx/0x2c26ad167d9c70290acef77e979c2beff430ceb56fd3cf7e180e14cfd8084ca2

Position key: `0xffd338a599306587763666b8f55f85e3fe52af66c013e7bcc5b05915639acf97`

## Reactive Phase

Lasna RVM processed the Unichain origin event:

- RVM tx: https://lasna.reactscan.net/tx/0xfb97cb88692543809fe3d7b3ca07fe85f5f2b9e33c4860896aaa209be0167db9
- RVM tx number: `0x644`
- Ref chain ID: `1301`
- Ref origin tx: `0x2c26ad167d9c70290acef77e979c2beff430ceb56fd3cf7e180e14cfd8084ca2`
- Ref event index: `2`

## Destination Callback Phase

Reactive callback tx on Unichain Sepolia:

- Destination callback / settlement tx: https://sepolia.uniscan.xyz/tx/0x02cc727fcf4f4043b86c3e883d99789584c091fba4d344c7e4e9497fea001255
- Receipt `to`: `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`
- Hook events emitted:
  - `ILSmoothed`
  - `ReactiveSettlementExecuted`

Decoded settlement:

- Total IL: `57.1` token0
- Smoothing factor: `7500` bps
- Reserve payout: `42.825` token0
- Final reserve balance: `9957.175` token0
- Position preview after callback: `0, 0, 0, 0`, confirming the position was settled and deleted

