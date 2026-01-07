;; Title: OracleStrike - Bitcoin Price Prediction Markets
;;
;; Summary:
;;   A sophisticated prediction market protocol built on Stacks, enabling users to 
;;   participate in Bitcoin price movement speculation through STX token staking.
;;
;; Description:
;;   OracleStrike transforms Bitcoin price speculation into a transparent, decentralized
;;   prediction market where participants stake STX tokens on directional BTC movements.
;;   The protocol features automated market resolution through oracle integration, 
;;   proportional reward distribution among winners, and robust economic incentives
;;   that align participant interests with market accuracy. Built specifically for
;;   the Bitcoin ecosystem via Stacks Layer 2, OracleStrike combines the security
;;   of Bitcoin with the programmability needed for complex financial instruments.
;;
;; Key Features:
;;   - Binary prediction markets (bullish/bearish)
;;   - Proportional reward distribution based on stake weight
;;   - Oracle-driven price resolution for market integrity  
;;   - Dynamic fee structure and configurable parameters
;;   - Automated lifecycle management with block-height triggers
;;   - Multi-layered security and fund protection mechanisms

;; ERROR CONSTANTS

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-invalid-prediction (err u102))
(define-constant err-market-closed (err u103))
(define-constant err-already-claimed (err u104))
(define-constant err-insufficient-balance (err u105))
(define-constant err-invalid-parameter (err u106))
(define-constant err-market-not-started (err u107))
(define-constant err-market-ended (err u108))
(define-constant err-market-already-resolved (err u109))

;; DATA VARIABLES

;; Oracle configuration for Bitcoin price feeds
(define-data-var oracle-address principal 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM)

;; Economic parameters
(define-data-var minimum-stake uint u1000000) ;; 1 STX minimum stake requirement
(define-data-var fee-percentage uint u2)      ;; 2% platform fee on winnings

;; Market tracking
(define-data-var market-counter uint u0)      ;; Incremental market identifier

;; DATA STRUCTURES

;; Core market data structure
(define-map markets
  uint ;; market-id
  {
    start-price: uint,        ;; BTC price at market creation
    end-price: uint,          ;; BTC price at resolution (0 if unresolved)
    total-up-stake: uint,     ;; Total STX staked on bullish predictions
    total-down-stake: uint,   ;; Total STX staked on bearish predictions
    start-block: uint,        ;; Block height when predictions open
    end-block: uint,          ;; Block height when market closes
    resolved: bool            ;; Resolution status
  }
)

;; Individual user prediction tracking
(define-map user-predictions
  {market-id: uint, user: principal}
  {
    prediction: (string-ascii 4), ;; "up" or "down"
    stake: uint,                  ;; Amount of STX staked
    claimed: bool                 ;; Reward claim status
  }
)

;; CORE MARKET FUNCTIONS

;; Creates a new Bitcoin price prediction market
;; @param start-price: Initial BTC price in micro-units
;; @param start-block: Block height when predictions begin
;; @param end-block: Block height when market closes
;; @returns: Market ID on success
(define-public (create-market (start-price uint) (start-block uint) (end-block uint))
  (let
    ((market-id (var-get market-counter)))
    
    ;; Validate permissions and parameters
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (> end-block start-block) err-invalid-parameter)
    (asserts! (> start-price u0) err-invalid-parameter)
    
    ;; Initialize market state
    (map-set markets market-id
      {
        start-price: start-price,
        end-price: u0,
        total-up-stake: u0,
        total-down-stake: u0,
        start-block: start-block,
        end-block: end-block,
        resolved: false
      }
    )
    
    ;; Increment market counter for next market
    (var-set market-counter (+ market-id u1))
    (ok market-id)
  )
)

;; Submits a price prediction with STX stake
;; @param market-id: Target market identifier
;; @param prediction: "up" for bullish, "down" for bearish
;; @param stake: Amount of STX to stake (in micro-STX)
;; @returns: Success boolean
(define-public (make-prediction (market-id uint) (prediction (string-ascii 4)) (stake uint))
  (let
    (
      (market (unwrap! (map-get? markets market-id) err-not-found))
      (current-block-height stacks-block-height)
    )
    
    ;; Validate market timing and state
    (asserts! (and (>= current-block-height (get start-block market)) 
                   (< current-block-height (get end-block market))) 
              err-market-ended)
    
    ;; Validate prediction parameters
    (asserts! (or (is-eq prediction "up") (is-eq prediction "down")) 
              err-invalid-prediction)
    (asserts! (>= stake (var-get minimum-stake)) err-invalid-prediction)
    (asserts! (<= stake (stx-get-balance tx-sender)) err-insufficient-balance)
    
    ;; Transfer stake to contract escrow
    (try! (stx-transfer? stake tx-sender (as-contract tx-sender)))
    
    ;; Record user prediction
    (map-set user-predictions {market-id: market-id, user: tx-sender}
      {prediction: prediction, stake: stake, claimed: false}
    )
    
    ;; Update market stake totals
    (map-set markets market-id
      (merge market
        {
          total-up-stake: (if (is-eq prediction "up")
                           (+ (get total-up-stake market) stake)
                           (get total-up-stake market)),
          total-down-stake: (if (is-eq prediction "down")
                            (+ (get total-down-stake market) stake)
                            (get total-down-stake market))
        }
      )
    )
    (ok true)
  )
)

;; Resolves market with final Bitcoin price
;; @param market-id: Market to resolve
;; @param end-price: Final BTC price for resolution
;; @returns: Success boolean
(define-public (resolve-market (market-id uint) (end-price uint))
  (let
    ((market (unwrap! (map-get? markets market-id) err-not-found)))
    
    ;; Validate oracle permissions and timing
    (asserts! (is-eq tx-sender (var-get oracle-address)) err-owner-only)
    (asserts! (>= stacks-block-height (get end-block market)) err-market-ended)
    (asserts! (not (get resolved market)) err-market-already-resolved)
    (asserts! (> end-price u0) err-invalid-parameter)
    
    ;; Mark market as resolved with final price
    (map-set markets market-id
      (merge market
        {
          end-price: end-price,
          resolved: true
        }
      )
    )
    (ok true)
  )
)

;; Claims winnings from resolved market
;; @param market-id: Market to claim from
;; @returns: Payout amount
(define-public (claim-winnings (market-id uint))
  (let
    (
      (market (unwrap! (map-get? markets market-id) err-not-found))
      (prediction (unwrap! (map-get? user-predictions 
                                    {market-id: market-id, user: tx-sender}) 
                          err-not-found))
    )
    
    ;; Validate market state and user eligibility
    (asserts! (get resolved market) err-market-closed)
    (asserts! (not (get claimed prediction)) err-already-claimed)
    
    (let
      (
        ;; Determine winning prediction based on price movement
        (winning-prediction (if (> (get end-price market) 
                                 (get start-price market)) 
                              "up" 
                              "down"))
        (total-stake (+ (get total-up-stake market) 
                       (get total-down-stake market)))
        (winning-stake (if (is-eq winning-prediction "up") 
                        (get total-up-stake market) 
                        (get total-down-stake market)))
      )
      
      ;; Verify user made winning prediction
      (asserts! (is-eq (get prediction prediction) winning-prediction) 
                err-invalid-prediction)
      
      (let
        (
          ;; Calculate proportional winnings
          (winnings (/ (* (get stake prediction) total-stake) winning-stake))
          (fee (/ (* winnings (var-get fee-percentage)) u100))
          (payout (- winnings fee))
        )
        
        ;; Transfer winnings and fees
        (try! (as-contract (stx-transfer? payout (as-contract tx-sender) tx-sender)))
        (try! (as-contract (stx-transfer? fee (as-contract tx-sender) contract-owner)))
        
        ;; Mark rewards as claimed
        (map-set user-predictions {market-id: market-id, user: tx-sender}
          (merge prediction {claimed: true})
        )
        (ok payout)
      )
    )
  )
)

;; READ-ONLY FUNCTIONS

;; Retrieves complete market information
;; @param market-id: Market identifier
;; @returns: Market data structure or none
(define-read-only (get-market (market-id uint))
  (map-get? markets market-id)
)

;; Retrieves user prediction details
;; @param market-id: Market identifier
;; @param user: User principal address
;; @returns: Prediction data structure or none
(define-read-only (get-user-prediction (market-id uint) (user principal))
  (map-get? user-predictions {market-id: market-id, user: user})
)

;; Returns current contract STX balance
;; @returns: Balance in micro-STX
(define-read-only (get-contract-balance)
  (stx-get-balance (as-contract tx-sender))
)

;; Returns current oracle address
;; @returns: Oracle principal address
(define-read-only (get-oracle-address)
  (var-get oracle-address)
)

;; Returns current minimum stake requirement
;; @returns: Minimum stake in micro-STX
(define-read-only (get-minimum-stake)
  (var-get minimum-stake)
)

;; Returns current platform fee percentage
;; @returns: Fee percentage (0-100)
(define-read-only (get-fee-percentage)
  (var-get fee-percentage)
)

;; Returns total number of markets created
;; @returns: Market counter value
(define-read-only (get-market-count)
  (var-get market-counter)
)

;; ADMINISTRATIVE FUNCTIONS

;; Updates the oracle address for price feeds
;; @param new-address: New oracle principal
;; @returns: Success boolean
(define-public (set-oracle-address (new-address principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (not (is-eq new-address (var-get oracle-address))) err-invalid-parameter)
    (ok (var-set oracle-address new-address))
  )
)

;; Updates minimum stake requirement
;; @param new-minimum: New minimum stake in micro-STX
;; @returns: Success boolean
(define-public (set-minimum-stake (new-minimum uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (> new-minimum u0) err-invalid-parameter)
    (ok (var-set minimum-stake new-minimum))
  )
)

;; Updates platform fee percentage
;; @param new-fee: New fee percentage (0-100)
;; @returns: Success boolean
(define-public (set-fee-percentage (new-fee uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (<= new-fee u100) err-invalid-parameter)
    (ok (var-set fee-percentage new-fee))
  )
)

;; Withdraws accumulated platform fees
;; @param amount: Amount to withdraw in micro-STX
;; @returns: Withdrawn amount
(define-public (withdraw-fees (amount uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (<= amount (stx-get-balance (as-contract tx-sender))) 
              err-insufficient-balance)
    (try! (as-contract (stx-transfer? amount (as-contract tx-sender) contract-owner)))
    (ok amount)
  )
)