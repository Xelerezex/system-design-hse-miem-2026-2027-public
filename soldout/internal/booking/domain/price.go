package domain

import (
	"fmt"
	"math/big"

	"github.com/nikolaysavelev/soldout/internal/booking/api"
)

// PriceForSoldCount applies round-half-up to the entire price after compound increases.
// Integer arithmetic avoids float rounding on sector tier boundaries.
func PriceForSoldCount(baseMinor int64, stepSeats, stepPercent, soldCount int) (int64, error) {
	if baseMinor <= 0 || stepSeats <= 0 || stepPercent < 0 || stepPercent > 100 || soldCount < 0 {
		return 0, fmt.Errorf("%w: invalid sector pricing rule", api.ErrValidation)
	}
	tier := soldCount / stepSeats
	if tier == 0 || stepPercent == 0 {
		return baseMinor, nil
	}
	num := new(big.Int).Exp(big.NewInt(int64(100+stepPercent)), big.NewInt(int64(tier)), nil)
	num.Mul(num, big.NewInt(baseMinor))
	den := new(big.Int).Exp(big.NewInt(100), big.NewInt(int64(tier)), nil)
	num.Mul(num, big.NewInt(2))
	num.Add(num, den)
	den.Mul(den, big.NewInt(2))
	price := num.Div(num, den)
	if !price.IsInt64() {
		return 0, fmt.Errorf("%w: sector price exceeds int64", api.ErrValidation)
	}
	return price.Int64(), nil
}
